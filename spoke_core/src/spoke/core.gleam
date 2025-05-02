import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/list
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

pub type Next {
  Next(state: State, outputs: List(Output))
}

type ConnectionState {
  NotConnected
  Connecting(options: packet.ConnectOptions)
  Connected(leftover_data: BitArray, acked: Bool)
}

pub opaque type State {
  State(session: Session, connection: ConnectionState)
}

pub fn new() -> State {
  State(session.new(False), NotConnected)
}

pub fn tick(state: State, time: Timestamp, input: Input) -> Result(Next, String) {
  case input {
    ReceivedData(data) -> Ok(receive(state, data))
    Tick -> todo
    TransportEstablished -> transport_established(state)
    TransportFailed(_) -> todo
    Perform(action) ->
      case action {
        Connect(options) -> connect(state, options)
        Disconnect -> Ok(disconnect(state))
      }
  }
}

fn connect(state: State, options: packet.ConnectOptions) -> Result(Next, String) {
  case state.connection {
    Connected(_, _) -> Error("Already connected")
    Connecting(_) -> Error("Already connecting")
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

      Ok(Next(State(session, Connecting(options)), [OpenTransport]))
    }
  }
}

fn disconnect(state: State) -> Next {
  let output = [CloseTransport]

  let output = case state.connection {
    Connected(_, True) -> [send(outgoing.Disconnect), ..output]
    _ -> output
  }

  Next(State(..state, connection: NotConnected), output)
}

fn transport_established(state: State) -> Result(Next, String) {
  case state.connection {
    Connecting(options) -> {
      let connect_packet = outgoing.Connect(options)
      Ok(
        Next(State(..state, connection: Connected(<<>>, False)), [
          send(connect_packet),
        ]),
      )
    }
    Connected(_, _) -> Error("Already connected")
    NotConnected -> Error("Not connecting")
  }
}

fn receive(state: State, data: BitArray) -> Next {
  case state.connection {
    Connected(leftover_data, acked) -> {
      let data = bit_array.append(leftover_data, data)
      let assert Ok(#(packets, leftover_data)) = incoming.decode_all(data)

      let state = State(..state, connection: Connected(leftover_data, acked))

      let Next(state, outputs) = {
        use Next(state, outputs), packet <- list.fold(packets, Next(state, []))

        case packet, acked {
          incoming.ConnAck(result), False ->
            handle_connack(state, result, outputs, leftover_data)

          incoming.ConnAck(_), True ->
            kill_connection(state, "Got CONNACK while already connected")

          _, False ->
            kill_connection(
              state,
              "The first packet sent from the Server to the Client MUST be a CONNACK Packet",
            )
          incoming.PingResp, True -> todo
          incoming.PubAck(_), True -> todo
          incoming.PubComp(_), True -> todo
          incoming.PubRec(_), True -> todo
          incoming.PubRel(_), True -> todo
          incoming.Publish(_), True -> todo
          incoming.SubAck(_, _), True -> todo
          incoming.UnsubAck(_), True -> todo
        }
      }

      Next(state, list.reverse(outputs))
    }

    Connecting(_) ->
      kill_connection(state, "Received data before sending CONNECT")

    NotConnected -> kill_connection(state, "Received data while not connected")
  }
}

fn handle_connack(
  state: State,
  result: packet.ConnAckResult,
  outputs: List(Output),
  leftover_data: BitArray,
) -> Next {
  let state = State(..state, connection: Connected(leftover_data, True))
  let outputs = [ReceivedConnectResponse(result), ..outputs]

  // TODO: Start pings

  // If a server sends a CONNACK packet containing a non-zero return code
  // it MUST then close the Network Connection.
  // We play it safe and close it anyway.
  case result {
    Ok(_) -> Next(state, outputs)
    Error(_) ->
      Next(State(..state, connection: NotConnected), [CloseTransport, ..outputs])
  }
}

fn noop(state: State) -> Next {
  Next(state, [])
}

fn kill_connection(state: State, error: String) -> Next {
  Next(State(..state, connection: NotConnected), [
    CloseTransportUnexpectedly(error),
  ])
}

fn send(packet: outgoing.Packet) -> Output {
  // TODO: Error handling
  let assert Ok(data) = outgoing.encode_packet(packet)
  SendData(data)
}
