import drift.{type Effect, type Timer}
import drift/reference.{type Reference}
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/core/internal/connection.{type Connection}
import spoke/core/internal/convert
import spoke/core/internal/session.{type Session}
import spoke/mqtt.{
  type OperationError, type PublishData, type SubscribeRequest,
  type Subscription, AtLeastOnce, AtMostOnce, ConnectionStateChanged,
  ExactlyOnce,
}
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/client/outgoing

pub type Command {
  Connect(clean_session: Bool, will: Option(PublishData))
  Disconnect
  Subscribe(
    List(SubscribeRequest),
    Effect(Result(List(Subscription), OperationError)),
  )
  PublishMessage(PublishData)
  GetPendingPublishes(Effect(Int))
  WaitForPublishesToFinish(Effect(Result(Nil, OperationError)), Int)
}

pub opaque type TimedAction {
  SendPing
  PingRespTimedOut
  ConnectTimedOut
  SubscribeTimedOut(Int)
  WaitForPublishesTimeout(Reference)
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
  ReturnPendingPublishes(Effect(Int), Int)
  PublishesCompleted(
    Effect(Result(Nil, OperationError)),
    Result(Nil, OperationError),
  )
  SubscribeCompleted(
    Effect(Result(List(Subscription), OperationError)),
    Result(List(Subscription), OperationError),
  )
}

pub opaque type State {
  State(
    options: Options,
    session: Session,
    connection: ConnectionState,
    pending_subs: Dict(Int, PendingSubscription),
    send_ping_timer: Option(Timer),
    ping_resp_timer: Option(Timer),
    connect_timer: Option(Timer),
    publish_completion_listeners: Dict(
      Reference,
      #(Effect(Result(Nil, OperationError)), Timer),
    ),
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
  State(
    options,
    session.new(False),
    NotConnected,
    dict.new(),
    None,
    None,
    None,
    dict.new(),
  )
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
        Subscribe(requests, effect) ->
          subscribe(context, state, requests, effect)
        PublishMessage(data) -> publish(context, state, data)
        GetPendingPublishes(reply) ->
          get_pending_publishes(context, state, reply)
        WaitForPublishesToFinish(reply, timeout) ->
          wait_for_publishes(context, state, reply, timeout)
      }
    Timeout(action) -> handle_timer(context, state, action)
  }
}

fn subscribe(
  context: Context,
  state: State,
  requests: List(SubscribeRequest),
  effect: Effect(Result(List(Subscription), OperationError)),
) -> Step {
  case state.connection {
    Connected(_) -> {
      let #(session, id) = session.reserve_packet_id(state.session)

      let #(context, timer) =
        drift.handle_after(
          context,
          state.options.server_timeout,
          Timeout(SubscribeTimedOut(id)),
        )

      let pending_subs =
        dict.insert(
          state.pending_subs,
          id,
          PendingSubscription(requests, effect, timer),
        )

      context
      |> drift.output(
        send(outgoing.Subscribe(
          id,
          list.map(requests, convert.to_packet_subscribe_request),
        )),
      )
      |> drift.continue(State(..state, session:, pending_subs:))
    }

    _ ->
      context
      |> drift.output(SubscribeCompleted(effect, Error(mqtt.NotConnected)))
      |> drift.continue(state)
  }
}

fn wait_for_publishes(
  context: Context,
  state: State,
  reply: Effect(Result(Nil, OperationError)),
  timeout: Int,
) -> Step {
  case session.pending_publishes(state.session) {
    0 ->
      context
      |> drift.output(PublishesCompleted(reply, Ok(Nil)))
      |> drift.continue(state)

    _ -> {
      let ref = reference.new()
      let #(context, timer) =
        drift.handle_after(
          context,
          timeout,
          Timeout(WaitForPublishesTimeout(ref)),
        )
      let publish_completion_listeners =
        dict.insert(state.publish_completion_listeners, ref, #(reply, timer))
      drift.continue(context, State(..state, publish_completion_listeners:))
    }
  }
}

//===== Privates =====//

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

type PendingSubscription {
  PendingSubscription(
    topics: List(SubscribeRequest),
    reply_to: Effect(Result(List(Subscription), OperationError)),
    timeout: Timer,
  )
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
        _ -> drift.continue(context, state)
      }
    }
    PingRespTimedOut ->
      disconnect_unexpectedly(context, state, "Ping response timed out")
    ConnectTimedOut ->
      disconnect_unexpectedly(context, state, "Connecting timed out")
    WaitForPublishesTimeout(ref) ->
      time_out_wait_for_publish(context, state, ref)
    SubscribeTimedOut(id) -> time_out_subscription(context, state, id)
  }
}

fn time_out_wait_for_publish(
  context: Context,
  state: State,
  ref: Reference,
) -> Step {
  let assert Ok(#(effect, _timer)) =
    dict.get(state.publish_completion_listeners, ref)

  context
  |> drift.output(PublishesCompleted(effect, Error(mqtt.OperationTimedOut)))
  |> drift.continue(state)
}

fn time_out_subscription(context: Context, state: State, id: Int) -> Step {
  let pending_subs = state.pending_subs

  case dict.get(pending_subs, id) {
    // If the key was not found, it means that the suback
    // and timeout were queued to be handled at the same time.
    Error(_) -> drift.continue(context, state)
    Ok(PendingSubscription(_, reply_to, _)) ->
      kill_connection(
        drift.output(
          context,
          SubscribeCompleted(reply_to, Error(mqtt.OperationTimedOut)),
        ),
        State(..state, pending_subs: dict.delete(pending_subs, id)),
        "Subscribe timed out",
      )
  }
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
      |> drift.continue(
        State(
          ..state,
          session:,
          connection: Connecting(options),
          connect_timer: Some(timer),
        ),
      )
    }

    // Trying to reconnect is a no-op
    _ -> drift.continue(context, state)
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
      |> drift.continue(State(..state, connection: Disconnecting))
    None -> unexpected_connection_state(context, state, "disconnecting")
  }
}

fn publish(context: Context, state: State, data: mqtt.PublishData) -> Step {
  let message =
    packet.MessageData(
      topic: data.topic,
      payload: data.payload,
      retain: data.retain,
    )

  let #(session, packet) = case data.qos {
    AtMostOnce -> #(
      state.session,
      outgoing.Publish(packet.PublishDataQoS0(message)),
    )
    AtLeastOnce -> session.start_qos1_publish(state.session, message)
    ExactlyOnce -> session.start_qos2_publish(state.session, message)
  }
  let state = State(..state, session:)

  case state.connection {
    Connected(_) ->
      context
      |> drift.output(send(packet))
      |> drift.continue(state)

    // QoS 0 packets are just dropped, QoS > 0 have been saved in the session
    _ -> drift.continue(context, state)
  }
}

fn get_pending_publishes(
  context: Context,
  state: State,
  reply: Effect(Int),
) -> Step {
  context
  |> drift.output(ReturnPendingPublishes(
    reply,
    session.pending_publishes(state.session),
  ))
  |> drift.continue(state)
}

fn transport_established(context: Context, state: State) -> Step {
  case state.connection {
    Connecting(options) -> {
      let connection = WaitingForConnAck(connection.new())
      context
      |> drift.output(send(outgoing.Connect(options)))
      |> drift.continue(State(..state, connection:))
    }
    _ -> unexpected_connection_state(context, state, "establishing transport")
  }
}

fn transport_closed(context: Context, state: State) -> Step {
  let change = case state.connection {
    Disconnecting -> mqtt.Disconnected
    _ -> mqtt.DisconnectedUnexpectedly("Transport closed")
  }

  context
  |> drift.cancel_all_timers()
  |> drift.output(Publish(ConnectionStateChanged(change)))
  |> drift.continue(State(..state, connection: NotConnected))
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
  |> drift.continue(State(..state, connection: NotConnected))
}

fn receive(context: Context, state: State, data: BitArray) -> Step {
  case state.connection {
    WaitingForConnAck(connection) -> {
      let assert Ok(#(connection, packet)) =
        connection.receive_one(connection, data)

      case packet {
        Some(packet) -> {
          let step = handle_first_packet(context, state, connection, packet)

          // Process the rest of the data
          // TODO add test!
          use context, state <- drift.chain(step)
          receive(context, state, <<>>)
        }
        None -> drift.continue(context, state)
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
      use context, state <- drift.chain(step)
      case packet {
        incoming.ConnAck(_) ->
          kill_connection(context, state, "Got CONNACK while already connected")
        incoming.PingResp -> drift.continue(context, state)
        incoming.PubAck(id) -> handle_puback(context, state, id)
        incoming.PubRec(id) -> handle_pubrec(context, state, id)
        incoming.PubComp(id) -> handle_pubcomp(context, state, id)
        incoming.PubRel(id) -> handle_pubrel(context, state, id)
        incoming.Publish(data) -> handle_publish(context, state, data)
        incoming.SubAck(id, return_codes) ->
          handle_suback(context, state, id, return_codes)
        incoming.UnsubAck(_) -> todo
      }
    }

    Connecting(..) ->
      kill_connection(context, state, "Received data before sending CONNECT")

    // These can easily happen if e.g. multiple receives are in the mailbox/event queue,
    // so we just ignore it.
    NotConnected -> drift.continue(context, state)
    Disconnecting -> drift.continue(context, state)
  }
}

fn handle_first_packet(
  context: Context,
  state: State,
  connection: Connection,
  packet: incoming.Packet,
) -> Step {
  case packet {
    incoming.ConnAck(result) -> {
      let update = ConnectionStateChanged(convert.to_connection_state(result))

      case result {
        Ok(_) ->
          context
          |> drift.output(Publish(update))
          |> drift.output_many(
            state.session
            |> session.packets_to_send_after_connect()
            |> list.map(send),
          )
          |> start_send_ping_timer(
            State(..state, connection: Connected(connection)),
          )
          |> drift.chain(reset_publish_completion)

        // If a server sends a CONNACK packet containing a non-zero return code
        // it MUST then close the Network Connection.
        // We play it safe and close it anyway.
        Error(_) ->
          context
          |> drift.output(Publish(update))
          |> drift.output(CloseTransport)
          |> drift.cancel_all_timers()
          |> drift.continue(State(..state, connection: NotConnected))
      }
    }

    _ ->
      kill_connection(
        context,
        state,
        "The first packet sent from the Server to the Client MUST be a CONNACK Packet",
      )
  }
}

fn handle_publish(
  context: Context,
  state: State,
  data: packet.PublishData,
) -> Step {
  let #(msg, session, packet) = case data {
    packet.PublishDataQoS0(msg) -> #(Some(msg), state.session, None)

    // dup is essentially useless,
    // as we don't know if we have already received this or not.
    packet.PublishDataQoS1(msg, _dup, id) -> #(
      Some(msg),
      state.session,
      Some(outgoing.PubAck(id)),
    )

    packet.PublishDataQoS2(msg, _dup, id) -> {
      let #(session, publish_result) =
        session.start_qos2_receive(state.session, id)
      let msg = case publish_result {
        True -> Some(msg)
        False -> None
      }
      #(msg, session, Some(outgoing.PubRec(id)))
    }
  }

  let context = case packet, state.connection {
    Some(packet), Connected(_) -> drift.output(context, send(packet))
    _, _ -> context
  }

  let context = case msg {
    Some(msg) ->
      drift.output(
        context,
        Publish(mqtt.ReceivedMessage(msg.topic, msg.payload, msg.retain)),
      )
    None -> context
  }

  drift.continue(context, State(..state, session:))
}

fn handle_suback(
  context: Context,
  state: State,
  id: Int,
  return_codes: List(Result(packet.QoS, Nil)),
) -> Step {
  let result = {
    let subs = state.pending_subs
    use pending_sub <- result.try(result.replace_error(
      dict.get(subs, id),
      "Received invalid packet id in subscribe ack",
    ))

    use pairs <- result.try(result.replace_error(
      list.strict_zip(pending_sub.topics, return_codes),
      "Received invalid number of results in subscribe ack",
    ))

    let results = list.map(pairs, convert.to_subscription)
    Ok(
      drift.cancel_timer(context, pending_sub.timeout).0
      |> drift.output(SubscribeCompleted(pending_sub.reply_to, Ok(results)))
      |> drift.continue(State(..state, pending_subs: dict.delete(subs, id))),
    )
  }

  case result {
    Error(e) -> {
      let errors = {
        use pending_sub <- list.map(dict.values(state.pending_subs))
        SubscribeCompleted(pending_sub.reply_to, Error(mqtt.ProtocolViolation))
      }

      kill_connection(
        drift.output_many(context, errors),
        State(..state, pending_subs: dict.new()),
        e,
      )
    }
    Ok(step) -> step
  }
}

fn handle_puback(context: Context, state: State, id: Int) -> Step {
  case session.handle_puback(state.session, id) {
    session.PublishFinished(session) -> {
      drift.continue(context, State(..state, session:))
    }
    session.InvalidPubAckId ->
      kill_connection(context, state, "Received invalid PubAck id")
  }
  |> drift.chain(check_publish_completion)
}

fn handle_pubrec(context: Context, state: State, id: Int) -> Step {
  context
  |> drift.output(send(outgoing.PubRel(id)))
  |> drift.continue(
    State(..state, session: session.handle_pubrec(state.session, id)),
  )
}

fn handle_pubcomp(context: Context, state: State, id: Int) -> Step {
  drift.continue(
    context,
    State(..state, session: session.handle_pubcomp(state.session, id)),
  )
  |> drift.chain(check_publish_completion)
}

fn handle_pubrel(context: Context, state: State, id: Int) -> Step {
  // TODO, what if not connected?
  context
  // Whether or not we already sent PubComp, we always do it when receiving PubRel.
  // This is in case we lose the connection after PubRec
  |> drift.output(send(outgoing.PubComp(id)))
  |> drift.continue(
    State(..state, session: session.handle_pubrel(state.session, id)),
  )
}

fn start_send_ping_timer(context: Context, state: State) -> Step {
  let context =
    context
    |> maybe_cancel_timer(state.send_ping_timer)
    |> maybe_cancel_timer(state.ping_resp_timer)
    |> maybe_cancel_timer(state.connect_timer)

  let #(context, timer) =
    drift.handle_after(context, state.options.keep_alive, Timeout(SendPing))

  drift.continue(
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

  drift.continue(context, State(..state, ping_resp_timer: Some(timer)))
}

fn check_publish_completion(context: Context, state: State) -> Step {
  check_publish_completion_with(context, state, Ok(Nil))
}

fn reset_publish_completion(context: Context, state: State) -> Step {
  check_publish_completion_with(context, state, Error(mqtt.SessionReset))
}

fn check_publish_completion_with(
  context: Context,
  state: State,
  result: Result(Nil, OperationError),
) -> Step {
  case session.pending_publishes(state.session) {
    0 -> {
      {
        use context, #(effect, timer) <- list.fold(
          dict.values(state.publish_completion_listeners),
          context,
        )
        let context = drift.cancel_timer(context, timer).0
        drift.output(context, PublishesCompleted(effect, result))
      }
      |> drift.continue(
        State(..state, publish_completion_listeners: dict.new()),
      )
    }
    _ -> drift.continue(context, state)
  }
}

fn kill_connection(context: Context, state: State, error: String) -> Step {
  context
  |> drift.cancel_all_timers()
  |> drift.output(CloseTransport)
  |> drift.output(
    Publish(ConnectionStateChanged(mqtt.DisconnectedUnexpectedly(error))),
  )
  |> drift.continue(State(..state, connection: NotConnected))
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
