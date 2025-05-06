import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/core/internal/connection.{type Connection}
import spoke/core/internal/convert
import spoke/core/internal/session.{type Session}
import spoke/core/internal/state
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

pub type TimedAction {
  SendPing
  PingRespTimedOut
  ConnectTimedOut
}

pub opaque type Client {
  Client(state: state.State(State, TimedAction))
}

pub fn new(options: mqtt.ConnectOptions(_)) -> Client {
  let options =
    Options(
      client_id: options.client_id,
      authentication: convert.to_auth_options(options.authentication),
      keep_alive: options.keep_alive_seconds * 1000,
      server_timeout: options.server_timeout_ms,
    )
  Client(state.new(State(options, session.new(False), NotConnected), []))
}

pub fn tick(
  client: Client,
  now: Timestamp,
) -> #(Client, Option(Timestamp), List(Output)) {
  state.tick(client.state, now, handle_timer)
  |> state.wrap(Client)
}

pub fn step(
  client: Client,
  now: Timestamp,
  input: Input,
) -> Result(#(Client, Option(Timestamp), List(Output)), String) {
  use #(state, next_tick, outputs) <- result.map(
    state.begin_step(client.state)
    |> handle_input(now, input)
    |> result.map(state.end_step),
  )

  #(Client(state), next_tick, outputs)
}

//--- Privates ---------------------------------------------------------------//

type State {
  State(options: Options, session: Session, connection: ConnectionState)
}

type Step =
  state.Step(State, TimedAction, Output)

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
  Connecting(options: packet.ConnectOptions)
  WaitingForConnAck(connection: Connection)
  Connected(connection: Connection)
  Disconnecting
}

fn handle_input(
  transaction: Step,
  now: Timestamp,
  input: Input,
) -> Result(Step, String) {
  case input {
    ReceivedData(data) -> Ok(receive(transaction, now, data))
    TransportEstablished -> transport_established(transaction)
    TransportFailed(error) -> Ok(disconnect_unexpectedly(transaction, error))
    TransportClosed -> transport_closed(transaction)
    Perform(action) ->
      case action {
        Connect(options, will) -> connect(transaction, now, options, will)
        Disconnect -> disconnect(transaction)
      }
  }
}

fn handle_timer(transaction: Step, now: Timestamp, action: TimedAction) -> Step {
  case action {
    SendPing -> {
      use state <- state.flat_map(transaction)
      case state.connection {
        Connected(connection) -> {
          let connection = Connected(connection)
          start_ping_timeout_timer(transaction, now)
          |> state.replace(State(..state, connection:))
          |> state.output(send(outgoing.PingReq))
        }
        _ -> transaction
      }
    }
    PingRespTimedOut ->
      disconnect_unexpectedly(transaction, "Ping response timed out")
    ConnectTimedOut ->
      disconnect_unexpectedly(transaction, "Connecting timed out")
  }
}

fn connect(
  transaction: Step,
  now: Timestamp,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Result(Step, String) {
  use state <- state.flat_map(transaction)
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

      let deadline = now + state.options.server_timeout
      let options =
        packet.ConnectOptions(
          clean_session:,
          client_id: state.options.client_id,
          keep_alive_seconds: state.options.keep_alive / 1000,
          auth: state.options.authentication,
          will: option.map(will, convert.to_will),
        )

      transaction
      |> state.replace(
        State(..state, session:, connection: Connecting(options)),
      )
      |> state.start_timer(state.Timer(deadline, ConnectTimedOut))
      |> state.output(OpenTransport)
      |> Ok
    }
    _ -> unexpected_connection_state(transaction, "connecting")
  }
}

fn disconnect(transaction: Step) -> Result(Step, String) {
  use state <- state.flat_map(transaction)
  let outputs = case state.connection {
    Connecting(..) -> Some([CloseTransport])
    WaitingForConnAck(..) -> Some([CloseTransport])
    Connected(..) -> Some([send(outgoing.Disconnect), CloseTransport])
    Disconnecting -> None
    NotConnected -> None
  }

  case outputs {
    Some(outputs) ->
      transaction
      |> state.replace(State(..state, connection: Disconnecting))
      |> state.output_many(outputs)
      |> Ok
    None -> unexpected_connection_state(transaction, "disconnecting")
  }
}

fn transport_established(transaction: Step) -> Result(Step, String) {
  use state <- state.flat_map(transaction)
  case state.connection {
    Connecting(options) -> {
      let connection = WaitingForConnAck(connection.new())
      transaction
      |> state.replace(State(..state, connection:))
      |> state.output(send(outgoing.Connect(options)))
      |> Ok
    }
    _ -> unexpected_connection_state(transaction, "establishing transport")
  }
}

fn transport_closed(transaction: Step) -> Result(Step, String) {
  use state <- state.flat_map(transaction)
  case state.connection {
    Disconnecting ->
      transaction
      |> state.cancel_all_timers()
      |> state.replace(State(..state, connection: NotConnected))
      |> state.output(Publish(ConnectionStateChanged(mqtt.Disconnected)))
      |> Ok
    _ ->
      unexpected_connection_state(transaction, "closing transport expectedly")
  }
}

fn disconnect_unexpectedly(transaction: Step, error: String) -> Step {
  use state <- state.flat_map(transaction)
  let change = case state.connection {
    // If we're already disconnected, just ignore this
    NotConnected -> None
    Connected(..) -> Some(mqtt.DisconnectedUnexpectedly(error))
    Disconnecting -> Some(mqtt.DisconnectedUnexpectedly(error))
    Connecting(..) -> Some(mqtt.ConnectFailed(error))
    WaitingForConnAck(..) -> Some(mqtt.ConnectFailed(error))
  }

  let outputs = case change {
    None -> []
    Some(change) -> [CloseTransport, Publish(ConnectionStateChanged(change))]
  }

  transaction
  |> state.replace(State(..state, connection: NotConnected))
  |> state.cancel_all_timers()
  |> state.output_many(outputs)
}

fn receive(transaction: Step, now: Timestamp, data: BitArray) -> Step {
  use state <- state.flat_map(transaction)
  case state.connection {
    WaitingForConnAck(connection) -> {
      let assert Ok(#(connection, packet)) =
        connection.receive_one(connection, data)

      case packet {
        None -> transaction
        Some(incoming.ConnAck(result)) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection.
          // We play it safe and close it anyway.
          let update =
            ConnectionStateChanged(convert.to_connection_state(result))
          let connection = Connected(connection)
          case result {
            Ok(_) ->
              transaction
              |> start_send_ping_timer(now)
              |> state.replace(State(..state, connection:))
              |> state.output(Publish(update))
            Error(_) ->
              transaction
              |> state.replace(State(..state, connection: NotConnected))
              |> state.output(Publish(update))
              |> state.output(CloseTransport)
              |> state.cancel_all_timers()
          }
        }

        Some(_) ->
          kill_connection(
            transaction,
            "The first packet sent from the Server to the Client MUST be a CONNACK Packet",
          )
      }
    }

    Connected(connection) -> {
      let assert Ok(#(connection, packets)) =
        connection.receive_all(connection, data)

      let transaction =
        transaction
        |> start_send_ping_timer(now)
        |> state.map(fn(state) {
          State(..state, connection: Connected(connection))
        })

      use transaction, packet <- list.fold(packets, transaction)
      case packet {
        incoming.ConnAck(_) ->
          kill_connection(transaction, "Got CONNACK while already connected")
        // TODO we should cancel a disconnect timer
        incoming.PingResp -> transaction
        incoming.PubAck(_) -> todo
        incoming.PubComp(_) -> todo
        incoming.PubRec(_) -> todo
        incoming.PubRel(_) -> todo
        incoming.Publish(_) -> todo
        incoming.SubAck(_, _) -> todo
        incoming.UnsubAck(_) -> todo
      }
    }

    Connecting(..) ->
      kill_connection(transaction, "Received data before sending CONNECT")

    // These can easily happen if e.g. multiple receives are in the mailbox/event queue,
    // so we just ignore it.
    NotConnected -> transaction
    Disconnecting -> transaction
  }
}

fn start_send_ping_timer(transaction: Step, now: Timestamp) -> Step {
  use state <- state.flat_map(transaction)
  transaction
  |> state.cancel_timer(fn(timer) {
    timer.data == SendPing
    || timer.data == PingRespTimedOut
    || timer.data == ConnectTimedOut
  })
  |> state.start_timer(state.Timer(now + state.options.keep_alive, SendPing))
}

fn start_ping_timeout_timer(transaction: Step, now: Timestamp) -> Step {
  use state <- state.flat_map(transaction)
  transaction
  |> state.start_timer(state.Timer(
    now + state.options.server_timeout,
    PingRespTimedOut,
  ))
}

fn kill_connection(transaction: Step, error: String) -> Step {
  transaction
  |> state.map(fn(state) { State(..state, connection: NotConnected) })
  |> state.cancel_all_timers()
  |> state.output(CloseTransport)
  |> state.output(
    Publish(ConnectionStateChanged(mqtt.DisconnectedUnexpectedly(error))),
  )
}

fn unexpected_connection_state(
  transaction: Step,
  operation: String,
) -> Result(Step, String) {
  use state <- state.error(transaction)
  "Unexpected connection state when "
  <> operation
  <> ": "
  <> case state.connection {
    Connected(..) -> "Connected"
    Connecting(..) -> "Connecting"
    Disconnecting -> "Disconnecting"
    NotConnected -> "Not connected"
    WaitingForConnAck(..) -> "Waiting for CONNACK"
  }
}

fn send(packet: outgoing.Packet) -> Output {
  // TODO: Error handling
  let assert Ok(data) = outgoing.encode_packet(packet)
  SendData(data)
}
