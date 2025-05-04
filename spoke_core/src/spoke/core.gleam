import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/core/internal/connection.{type Connection}
import spoke/core/internal/convert
import spoke/core/internal/session.{type Session}
import spoke/core/internal/timer
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

pub type TimedAction {
  SendPing
  PingRespTimedOut
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
    TransportEstablished -> transport_established(state)
    TransportFailed(error) -> Ok(disconnect_unexpectedly(state, error))
    TransportClosed -> transport_closed(state)
    Perform(action) ->
      case action {
        Connect(options, will) -> connect(state, time, options, will)
        Disconnect -> disconnect(state)
      }
  })

  #(state, next_tick(state), outputs)
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
  Connected(timers: timer.TimerPool(TimedAction), connection: Connection)
  Disconnecting
}

type Next =
  #(State, List(Output))

fn next_tick(state: State) -> Option(Int) {
  case state.connection {
    Connected(timers, ..) -> timer.next(timers)
    Connecting(deadline, _) -> Some(deadline)
    WaitingForConnAck(deadline, _) -> Some(deadline)
    Disconnecting -> None
    NotConnected -> None
  }
}

fn handle_tick(state: State, now: Timestamp) -> Next {
  case state.connection {
    Connected(timers, connection) -> {
      let #(expired, timers) = timer.drain(timers, now)
      let state = State(..state, connection: Connected(timers, connection))
      fold_next(state, expired, fn(state, timer) {
        handle_timer(state, now, timer)
      })
    }
    Connecting(deadline, _) -> maybe_time_out_connection(state, now, deadline)
    WaitingForConnAck(deadline, _) ->
      maybe_time_out_connection(state, now, deadline)
    Disconnecting -> noop(state)
    NotConnected -> noop(state)
  }
}

fn handle_timer(
  state: State,
  now: Timestamp,
  timer: timer.Timer(TimedAction),
) -> Next {
  case timer.data {
    SendPing -> {
      case state.connection {
        Connected(timers, connection) -> {
          let timers = start_ping_timeout_timer(timers, now, state)
          let connection = Connected(timers, connection)
          #(State(..state, connection:), [send(outgoing.PingReq)])
        }
        _ -> noop(state)
      }
    }
    PingRespTimedOut ->
      disconnect_unexpectedly(state, "Ping response timed out")
  }
}

fn maybe_time_out_connection(
  state: State,
  now: Timestamp,
  deadline: Timestamp,
) -> Next {
  case now >= deadline {
    True -> server_timeout(state)
    False -> noop(state)
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
    Connected(..) -> Some([send(outgoing.Disconnect), CloseTransport])
    Disconnecting -> None
    NotConnected -> None
  }

  case outputs {
    Some(outputs) -> Ok(#(State(..state, connection: Disconnecting), outputs))
    None -> unexpected_connection_state(state, "disconnecting")
  }
}

fn transport_established(state: State) -> Result(Next, String) {
  case state.connection {
    Connecting(deadline, options) -> {
      let connection = WaitingForConnAck(deadline, connection.new())
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

fn server_timeout(state: State) -> Next {
  disconnect_unexpectedly(state, "Operation timed out")
}

fn disconnect_unexpectedly(state: State, error: String) -> Next {
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

  #(State(..state, connection: NotConnected), outputs)
}

fn receive(state: State, now: Timestamp, data: BitArray) -> Next {
  case state.connection {
    WaitingForConnAck(_deadline, connection) -> {
      let assert Ok(#(connection, packet)) =
        connection.receive_one(connection, data)

      case packet {
        None -> #(state, [])
        Some(incoming.ConnAck(result)) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection.
          // We play it safe and close it anyway.
          let update =
            ConnectionStateChanged(convert.to_connection_state(result))
          let connection =
            Connected(
              timer.new_pool() |> start_send_ping_timer(now, state),
              connection,
            )
          case result {
            Ok(_) -> #(State(..state, connection:), [Publish(update)])
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

    Connected(timers, connection) -> {
      let assert Ok(#(connection, packets)) =
        connection.receive_all(connection, data)
      let timers = timers |> start_send_ping_timer(now, state)
      let state = State(..state, connection: Connected(timers, connection))

      use state, packet <- fold_next(state, packets)
      case packet {
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
    }

    Connecting(..) ->
      kill_connection(state, "Received data before sending CONNECT")

    // These can easily happen if e.g. multiple receives are in the mailbox/event queue,
    // so we just ignore it.
    NotConnected -> noop(state)
    Disconnecting -> noop(state)
  }
}

fn start_send_ping_timer(
  timers: timer.TimerPool(TimedAction),
  now: Timestamp,
  state: State,
) -> timer.TimerPool(TimedAction) {
  timers
  |> timer.remove(fn(timer) {
    timer.data == SendPing || timer.data == PingRespTimedOut
  })
  |> timer.add(timer.Timer(now + state.options.keep_alive, SendPing))
}

fn start_ping_timeout_timer(
  timers: timer.TimerPool(TimedAction),
  now: Timestamp,
  state: State,
) -> timer.TimerPool(TimedAction) {
  timers
  |> timer.add(timer.Timer(now + state.options.server_timeout, PingRespTimedOut))
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

fn fold_next(state: State, items: List(a), fun: fn(State, a) -> Next) -> Next {
  let #(state, outputs) = {
    use #(state, outputs), item <- list.fold(items, #(state, [[]]))
    let #(state, new_outputs) = fun(state, item)
    #(state, [new_outputs, ..outputs])
  }
  #(state, outputs |> list.reverse |> list.flatten)
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
