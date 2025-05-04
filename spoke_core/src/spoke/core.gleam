import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/core/internal/connection.{type Connection}
import spoke/core/internal/session.{type Session}
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/client/outgoing

pub type Timestamp =
  Int

pub type OperationId =
  Int

pub type Action {
  Connect(packet.ConnectOptions)
  Disconnect
}

pub type Input {
  Tick
  TransportEstablished
  TransportFailed(String)
  ReceivedData(BitArray)
  Perform(Action)
}

pub type Output {
  OpenTransport
  CloseTransport
  CloseTransportUnexpectedly(String)
  SendData(BytesTree)
  ReceivedMessage(packet.MessageData)
  ReceivedConnectResponse(packet.ConnAckResult)
}

type ConnectionState {
  NotConnected
  Connecting(options: packet.ConnectOptions)
  WaitingForConnAck(Connection)
  Connected(Connection)
}

pub opaque type State {
  State(session: Session, connection: ConnectionState)
}

type Next =
  #(State, List(Output))

pub fn new() -> State {
  State(session.new(False), NotConnected)
}

pub fn tick(
  state: State,
  time: Timestamp,
  input: Input,
) -> Result(#(State, Option(Timestamp), List(Output)), String) {
  use #(state, outputs) <- result.map(case input {
    ReceivedData(data) -> Ok(receive(state, time, data))
    Tick -> Ok(handle_tick(state, time))
    TransportEstablished -> transport_established(state, time)
    TransportFailed(_) -> todo
    Perform(action) ->
      case action {
        Connect(options) -> connect(state, time, options)
        Disconnect -> Ok(disconnect(state))
      }
  })

  #(state, next_ping(state), outputs)
}

fn next_ping(state: State) -> Option(Int) {
  case state.connection {
    Connected(c, ..) -> connection.next_ping(c)
    _ -> None
  }
}

fn handle_tick(state: State, time: Timestamp) -> Next {
  case state.connection {
    Connected(c, ..) ->
      case connection.next_ping(c) {
        Some(ping_time) if ping_time <= time -> {
          #(State(..state, connection: Connected(connection.sent_ping(c))), [
            send(outgoing.PingReq),
          ])
        }
        _ -> noop(state)
      }
    _ -> noop(state)
  }
}

fn connect(
  state: State,
  time: Timestamp,
  options: packet.ConnectOptions,
) -> Result(Next, String) {
  case state.connection {
    Connected(..) -> Error("Already connected")
    Connecting(_) -> Error("Already connecting")
    WaitingForConnAck(_) -> Error("Already connecting")
    NotConnected -> {
      // [MQTT-3.1.2-6]
      // If CleanSession is set to 1,
      // the Client and Server MUST discard any previous Session and start a new one.
      // This Session lasts as long as the Network Connection.
      // State data associated with this Session MUST NOT be reused in any subsequent Session.
      let session = case
        options.clean_session || session.is_ephemeral(state.session)
      {
        True -> session.new(options.clean_session)
        False -> state.session
      }

      Ok(#(State(session, Connecting(options)), [OpenTransport]))
    }
  }
}

fn disconnect(state: State) -> Next {
  let output = [CloseTransport]

  let output = case state.connection {
    Connected(..) -> [send(outgoing.Disconnect), ..output]
    _ -> output
  }

  #(State(..state, connection: NotConnected), output)
}

fn transport_established(state: State, time: Timestamp) -> Result(Next, String) {
  case state.connection {
    Connecting(options) -> {
      let connect_packet = outgoing.Connect(options)
      let keep_alive = options.keep_alive_seconds * 1000
      let connection = WaitingForConnAck(connection.new(time, keep_alive))

      Ok(#(State(..state, connection:), [send(connect_packet)]))
    }
    WaitingForConnAck(..) -> Error("Already connecting")
    Connected(..) -> Error("Already connected")
    NotConnected -> Error("Not connecting")
  }
}

fn receive(state: State, time: Timestamp, data: BitArray) -> Next {
  case state.connection {
    WaitingForConnAck(connection) -> {
      let assert Ok(#(connection, packet)) =
        connection.receive_one(connection, time, data)
      let state = State(..state, connection: Connected(connection))

      case packet {
        None -> #(state, [])
        Some(incoming.ConnAck(result)) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection.
          // We play it safe and close it anyway.
          case result {
            Ok(_) -> #(State(..state, connection: Connected(connection)), [
              ReceivedConnectResponse(result),
            ])
            Error(_) -> #(State(..state, connection: NotConnected), [
              ReceivedConnectResponse(result),
              CloseTransport,
            ])
          }
        }

        Some(_) ->
          kill_connection(
            state,
            "The first packet sent from the Server to the Client MUST be a CONNACK Packet",
          )
      }
    }

    Connected(connection) -> {
      let assert Ok(#(connection, packets)) =
        connection.receive_all(connection, time, data)
      let state = State(..state, connection: Connected(connection))

      let #(state, outputs) = {
        use #(state, outputs), packet <- list.fold(packets, #(state, []))

        case packet {
          incoming.ConnAck(_) ->
            kill_connection(state, "Got CONNACK while already connected")
          incoming.PingResp -> #(state, outputs)
          incoming.PubAck(_) -> todo
          incoming.PubComp(_) -> todo
          incoming.PubRec(_) -> todo
          incoming.PubRel(_) -> todo
          incoming.Publish(_) -> todo
          incoming.SubAck(_, _) -> todo
          incoming.UnsubAck(_) -> todo
        }
      }

      #(state, list.reverse(outputs))
    }

    Connecting(_) ->
      kill_connection(state, "Received data before sending CONNECT")

    NotConnected -> kill_connection(state, "Received data while not connected")
  }
}

fn kill_connection(state: State, error: String) -> Next {
  #(State(..state, connection: NotConnected), [
    CloseTransportUnexpectedly(error),
  ])
}

fn noop(state: State) -> Next {
  #(state, [])
}

fn send(packet: outgoing.Packet) -> Output {
  // TODO: Error handling
  let assert Ok(data) = outgoing.encode_packet(packet)
  SendData(data)
}
