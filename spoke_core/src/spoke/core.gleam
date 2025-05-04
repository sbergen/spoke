import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/core/internal/connection.{type Connection}
import spoke/core/internal/convert
import spoke/core/internal/session.{type Session}
import spoke/mqtt.{ConnectionStateChanged}
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/client/outgoing

pub type Timestamp =
  Int

pub type OperationId =
  Int

pub type Command {
  Connect(clean_session: Bool, will: Option(mqtt.PublishData))
  Disconnect
}

pub type Input {
  Perform(Command)
  Tick
  TransportEstablished
  TransportFailed(String)
  TransportClosed
  ReceivedData(BitArray)
}

pub type Output {
  Publish(mqtt.Update)
  OpenTransport
  CloseTransport
  SendData(BytesTree)
}

pub opaque type State {
  State(options: Options, session: Session, connection: ConnectionState)
}

pub fn new(options: mqtt.ConnectOptions(_)) -> State {
  let options =
    Options(
      client_id: options.client_id,
      authentication: convert.to_auth_options(options.authentication),
      keep_alive: options.keep_alive_seconds * 1000,
      server_timeout: options.server_timeout_ms,
    )
  State(options, session.new(False), NotConnected)
}

pub fn update(
  state: State,
  time: Timestamp,
  input: Input,
) -> Result(#(State, Option(Timestamp), List(Output)), String) {
  use #(state, outputs) <- result.map(case input {
    ReceivedData(data) -> Ok(receive(state, time, data))
    Tick -> Ok(handle_tick(state, time))
    TransportEstablished -> transport_established(state, time)
    TransportFailed(error) -> Ok(transport_failed(state, error))
    TransportClosed -> transport_closed(state)
    Perform(action) ->
      case action {
        Connect(options, will) -> connect(state, time, options, will)
        Disconnect -> disconnect(state)
      }
  })

  #(state, next_ping(state), outputs)
}

//--- Privates ---------------------------------------------------------------//

// Drops the transport options and the generics from the public type
type Options {
  Options(
    client_id: String,
    authentication: Option(packet.AuthOptions),
    keep_alive: Int,
    server_timeout: Int,
  )
}

type ConnectionState {
  NotConnected
  Connecting(deadline: Timestamp, options: packet.ConnectOptions)
  WaitingForConnAck(deadline: Timestamp, connection: Connection)
  Connected(Connection)
  Disconnecting
}

type Next =
  #(State, List(Output))

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
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Result(Next, String) {
  case state.connection {
    NotConnected -> {
      // [MQTT-3.1.2-6]
      // If CleanSession is set to 1,
      // the Client and Server MUST discard any previous Session and start a new one.
      // This Session lasts as long as the Network Connection.
      // State data associated with this Session MUST NOT be reused in any subsequent Session.
      let session = case clean_session || session.is_ephemeral(state.session) {
        True -> session.new(clean_session)
        False -> state.session
      }

      let deadline = time + state.options.server_timeout
      let options =
        packet.ConnectOptions(
          clean_session:,
          client_id: state.options.client_id,
          keep_alive_seconds: state.options.keep_alive / 1000,
          auth: state.options.authentication,
          will: option.map(will, convert.to_will),
        )

      Ok(
        #(State(..state, session:, connection: Connecting(deadline, options)), [
          OpenTransport,
        ]),
      )
    }
    _ -> unexpected_connection_state(state, "connecting")
  }
}

fn disconnect(state: State) -> Result(Next, String) {
  let outputs = case state.connection {
    Connecting(..) -> Some([CloseTransport])
    WaitingForConnAck(..) -> Some([CloseTransport])
    Connected(_) -> Some([send(outgoing.Disconnect), CloseTransport])
    Disconnecting -> None
    NotConnected -> None
  }

  case outputs {
    Some(outputs) -> Ok(#(State(..state, connection: Disconnecting), outputs))
    None -> unexpected_connection_state(state, "disconnecting")
  }
}

fn transport_established(state: State, time: Timestamp) -> Result(Next, String) {
  case state.connection {
    Connecting(deadline, options) -> {
      let keep_alive = options.keep_alive_seconds * 1000
      let connection = connection.new(time, keep_alive)
      let connection = WaitingForConnAck(deadline, connection)

      Ok(#(State(..state, connection:), [send(outgoing.Connect(options))]))
    }
    _ -> unexpected_connection_state(state, "establishing transport")
  }
}

fn transport_closed(state: State) -> Result(Next, String) {
  case state.connection {
    Disconnecting ->
      Ok(
        #(State(..state, connection: NotConnected), [
          Publish(ConnectionStateChanged(mqtt.Disconnected)),
        ]),
      )
    _ -> unexpected_connection_state(state, "closing transport expectedly")
  }
}

fn transport_failed(state: State, error: String) -> Next {
  let change = case state.connection {
    // If we're already disconnected, just ignore this
    NotConnected -> None
    Connected(_) -> Some(mqtt.DisconnectedUnexpectedly(error))
    Disconnecting -> Some(mqtt.DisconnectedUnexpectedly(error))
    Connecting(..) -> Some(mqtt.ConnectFailed(error))
    WaitingForConnAck(..) -> Some(mqtt.ConnectFailed(error))
  }

  let updates = case change {
    None -> []
    Some(change) -> [Publish(ConnectionStateChanged(change))]
  }

  #(State(..state, connection: NotConnected), updates)
}

fn receive(state: State, time: Timestamp, data: BitArray) -> Next {
  case state.connection {
    WaitingForConnAck(_deadline, connection) -> {
      let assert Ok(#(connection, packet)) =
        connection.receive_one(connection, time, data)
      let state = State(..state, connection: Connected(connection))

      case packet {
        None -> #(state, [])
        Some(incoming.ConnAck(result)) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection.
          // We play it safe and close it anyway.
          let update =
            ConnectionStateChanged(convert.to_connection_state(result))
          case result {
            Ok(_) -> #(State(..state, connection: Connected(connection)), [
              Publish(update),
            ])
            Error(_) -> #(State(..state, connection: NotConnected), [
              Publish(update),
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
        use #(state, outputs), packet <- list.fold(packets, #(state, [[]]))

        let #(state, new_outputs) = case packet {
          incoming.ConnAck(_) ->
            kill_connection(state, "Got CONNACK while already connected")
          // TODO
          incoming.PingResp -> noop(state)
          incoming.PubAck(_) -> todo
          incoming.PubComp(_) -> todo
          incoming.PubRec(_) -> todo
          incoming.PubRel(_) -> todo
          incoming.Publish(_) -> todo
          incoming.SubAck(_, _) -> todo
          incoming.UnsubAck(_) -> todo
        }

        #(state, [new_outputs, ..outputs])
      }

      #(state, outputs |> list.reverse |> list.flatten)
    }

    Connecting(..) ->
      kill_connection(state, "Received data before sending CONNECT")

    // These can easily happen if e.g. multiple receives are in the mailbox/event queue,
    // so we just ignore it.
    NotConnected -> noop(state)
    Disconnecting -> noop(state)
  }
}

fn kill_connection(state: State, error: String) -> Next {
  #(State(..state, connection: NotConnected), [
    CloseTransport,
    Publish(ConnectionStateChanged(mqtt.DisconnectedUnexpectedly(error))),
  ])
}

fn noop(state: State) -> Next {
  #(state, [])
}

fn unexpected_connection_state(
  state: State,
  operation: String,
) -> Result(Next, String) {
  Error(
    "Unexpected connection state when "
    <> operation
    <> ": "
    <> case state.connection {
      Connected(_) -> "Connected"
      Connecting(..) -> "Connecting"
      Disconnecting -> "Disconnecting"
      NotConnected -> "Not connected"
      WaitingForConnAck(..) -> "Waiting for CONNACK"
    },
  )
}

fn send(packet: outgoing.Packet) -> Output {
  // TODO: Error handling
  let assert Ok(data) = outgoing.encode_packet(packet)
  SendData(data)
}
