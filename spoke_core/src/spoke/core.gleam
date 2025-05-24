import drift
import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/option.{type Option, None, Some}
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
  TransportEstablished
  TransportFailed(String)
  TransportClosed
  ReceivedData(BitArray)
  Timeout(TimedAction)
}

pub type Output {
  Publish(mqtt.Update)
  OpenTransport
  CloseTransport
  SendData(BytesTree)
}

pub opaque type TimedAction {
  SendPing
  PingRespTimedOut
  ConnectTimedOut
}

pub opaque type State {
  State(
    options: Options,
    session: Session,
    connection: ConnectionState,
    send_ping_timer: Option(drift.Timer),
    ping_resp_timer: Option(drift.Timer),
    connect_timer: Option(drift.Timer),
  )
}

pub type Step =
  drift.Step(State, Input, Output, String)

pub type Context =
  drift.Context(Input, Output)

pub fn new_state(options: mqtt.ConnectOptions(_)) -> State {
  let options =
    Options(
      client_id: options.client_id,
      authentication: convert.to_auth_options(options.authentication),
      keep_alive: options.keep_alive_seconds * 1000,
      server_timeout: options.server_timeout_ms,
    )
  State(options, session.new(False), NotConnected, None, None, None)
}

pub fn handle_input(context: Context, state: State, input: Input) -> Step {
  case input {
    ReceivedData(data) -> receive(context, state, data)
    TransportEstablished -> transport_established(context, state)
    TransportFailed(error) -> disconnect_unexpectedly(context, state, error)
    TransportClosed -> transport_closed(context, state)
    Perform(action) ->
      case action {
        Connect(options, will) -> connect(context, state, options, will)
        Disconnect -> disconnect(context, state)
      }
    Timeout(action) -> handle_timer(context, state, action)
  }
}

fn handle_timer(context: Context, state: State, action: TimedAction) -> Step {
  case action {
    SendPing -> {
      case state.connection {
        Connected(_) -> {
          context
          |> drift.output(send(outgoing.PingReq))
          |> start_ping_timeout_timer(state)
        }
        _ -> drift.with_state(context, state)
      }
    }
    PingRespTimedOut ->
      disconnect_unexpectedly(context, state, "Ping response timed out")
    ConnectTimedOut ->
      disconnect_unexpectedly(context, state, "Connecting timed out")
  }
}

//===== Privates =====//

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

fn connect(
  context: Context,
  state: State,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Step {
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

      let options =
        packet.ConnectOptions(
          clean_session:,
          client_id: state.options.client_id,
          keep_alive_seconds: state.options.keep_alive / 1000,
          auth: state.options.authentication,
          will: option.map(will, convert.to_will),
        )

      let #(context, timer) =
        drift.handle_after(
          context,
          state.options.server_timeout,
          Timeout(ConnectTimedOut),
        )

      context
      |> drift.output(OpenTransport)
      |> drift.with_state(
        State(
          ..state,
          session:,
          connection: Connecting(options),
          connect_timer: Some(timer),
        ),
      )
    }
    _ -> unexpected_connection_state(context, state, "connecting")
  }
}

fn disconnect(context: Context, state: State) -> Step {
  let outputs = case state.connection {
    Connecting(..) -> Some([CloseTransport])
    WaitingForConnAck(..) -> Some([CloseTransport])
    Connected(..) -> Some([send(outgoing.Disconnect), CloseTransport])
    Disconnecting -> None
    NotConnected -> None
  }

  case outputs {
    Some(outputs) ->
      context
      |> drift.output_many(outputs)
      |> drift.with_state(State(..state, connection: Disconnecting))
    None -> unexpected_connection_state(context, state, "disconnecting")
  }
}

fn transport_established(context: Context, state: State) -> Step {
  case state.connection {
    Connecting(options) -> {
      let connection = WaitingForConnAck(connection.new())
      context
      |> drift.output(send(outgoing.Connect(options)))
      |> drift.with_state(State(..state, connection:))
    }
    _ -> unexpected_connection_state(context, state, "establishing transport")
  }
}

fn transport_closed(context: Context, state: State) -> Step {
  case state.connection {
    Disconnecting ->
      context
      |> drift.cancel_all_timers()
      |> drift.output(Publish(ConnectionStateChanged(mqtt.Disconnected)))
      |> drift.with_state(State(..state, connection: NotConnected))
    _ ->
      unexpected_connection_state(
        context,
        state,
        "closing transport expectedly",
      )
  }
}

fn disconnect_unexpectedly(
  context: Context,
  state: State,
  error: String,
) -> Step {
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

  context
  |> drift.cancel_all_timers()
  |> drift.output_many(outputs)
  |> drift.with_state(State(..state, connection: NotConnected))
}

fn receive(context: Context, state: State, data: BitArray) -> Step {
  case state.connection {
    WaitingForConnAck(connection) -> {
      let assert Ok(#(connection, packet)) =
        connection.receive_one(connection, data)

      case packet {
        None -> drift.with_state(context, state)
        Some(incoming.ConnAck(result)) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection.
          // We play it safe and close it anyway.
          let update =
            ConnectionStateChanged(convert.to_connection_state(result))
          let connection = Connected(connection)
          case result {
            Ok(_) ->
              context
              |> drift.output(Publish(update))
              |> start_send_ping_timer(State(..state, connection:))
            Error(_) ->
              context
              |> drift.output(Publish(update))
              |> drift.output(CloseTransport)
              |> drift.cancel_all_timers()
              |> drift.with_state(State(..state, connection: NotConnected))
          }
        }

        Some(_) ->
          kill_connection(
            context,
            state,
            "The first packet sent from the Server to the Client MUST be a CONNACK Packet",
          )
      }
    }

    Connected(connection) -> {
      let assert Ok(#(connection, packets)) =
        connection.receive_all(connection, data)

      let step =
        start_send_ping_timer(
          context,
          State(..state, connection: Connected(connection)),
        )

      use step, packet <- list.fold(packets, step)
      use context, state <- drift.continue(step)
      case packet {
        incoming.ConnAck(_) ->
          kill_connection(context, state, "Got CONNACK while already connected")
        // TODO we should cancel a disconnect timer
        incoming.PingResp -> drift.with_state(context, state)
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
      kill_connection(context, state, "Received data before sending CONNECT")

    // These can easily happen if e.g. multiple receives are in the mailbox/event queue,
    // so we just ignore it.
    NotConnected -> drift.with_state(context, state)
    Disconnecting -> drift.with_state(context, state)
  }
}

fn start_send_ping_timer(context: Context, state: State) -> Step {
  let context =
    context
    |> maybe_cancel_timer(state.send_ping_timer)
    |> maybe_cancel_timer(state.ping_resp_timer)
    |> maybe_cancel_timer(state.connect_timer)

  let #(context, timer) =
    drift.handle_after(context, state.options.keep_alive, Timeout(SendPing))

  drift.with_state(
    context,
    State(
      ..state,
      send_ping_timer: Some(timer),
      ping_resp_timer: None,
      connect_timer: None,
    ),
  )
}

fn start_ping_timeout_timer(context: Context, state: State) -> Step {
  let context = maybe_cancel_timer(context, state.ping_resp_timer)

  let #(context, timer) =
    drift.handle_after(
      context,
      state.options.server_timeout,
      Timeout(PingRespTimedOut),
    )

  drift.with_state(context, State(..state, ping_resp_timer: Some(timer)))
}

fn kill_connection(context: Context, state: State, error: String) -> Step {
  context
  |> drift.cancel_all_timers()
  |> drift.output(CloseTransport)
  |> drift.output(
    Publish(ConnectionStateChanged(mqtt.DisconnectedUnexpectedly(error))),
  )
  |> drift.with_state(State(..state, connection: NotConnected))
}

fn unexpected_connection_state(
  context: Context,
  state: State,
  operation: String,
) -> Step {
  drift.stop_with_error(
    context,
    "Unexpected connection state when "
      <> operation
      <> ": "
      <> case state.connection {
      Connected(..) -> "Connected"
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

fn maybe_cancel_timer(context: Context, timer: Option(drift.Timer)) -> Context {
  case timer {
    Some(timer) -> drift.cancel_timer(context, timer).0
    None -> context
  }
}
