import drift.{type Action, type Effect, type Timer}
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
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

type OperationResult(a) =
  Result(a, OperationError)

type PublishCompletionEffect =
  Effect(OperationResult(Nil))

pub type Command {
  SubscribeToUpdates(Effect(mqtt.Update))
  UnsubscribeFromUpdates(Effect(mqtt.Update))
  Connect(clean_session: Bool, will: Option(PublishData))
  Disconnect(Effect(Nil))
  Subscribe(List(SubscribeRequest), Effect(OperationResult(List(Subscription))))
  Unsubscribe(List(String), Effect(OperationResult(Nil)))
  PublishMessage(PublishData)
  GetPendingPublishes(Effect(Int))
  WaitForPublishesToFinish(Effect(OperationResult(Nil)), Int)
}

pub opaque type TimedAction {
  SendPing
  PingRespTimedOut
  ConnectTimedOut
  SubscribeTimedOut(Int)
  UnsubscribeTimedOut(Int)
  WaitForPublishesTimeout(PublishCompletionEffect)
}

pub type TransportEvent {
  TransportEstablished
  TransportFailed(String)
  TransportClosed
  ReceivedData(BitArray)
}

pub type Input {
  Perform(Command)
  Handle(TransportEvent)
  Timeout(TimedAction)
}

pub type Output {
  Publish(Action(mqtt.Update))
  OpenTransport
  CloseTransport
  SendData(BytesTree)
  ReturnPendingPublishes(Action(Int))
  PublishesCompleted(Action(OperationResult(Nil)))
  SubscribeCompleted(Action(OperationResult(List(Subscription))))
  UnsubscribeCompleted(Action(OperationResult(Nil)))
  CompleteDisconnect(Action(Nil))
}

pub opaque type State {
  State(
    options: Options,
    session: Session,
    connection: ConnectionState,
    pending_subs: Dict(Int, PendingSubscription),
    pending_unsubs: Dict(Int, PendingUnsubscribe),
    send_ping_timer: Option(Timer),
    ping_resp_timer: Option(Timer),
    connect_timer: Option(Timer),
    update_listeners: Set(Effect(mqtt.Update)),
    publish_completion_listeners: Dict(PublishCompletionEffect, Timer),
  )
}

pub type Step =
  drift.Step(State, Input, Output, String)

pub type Context =
  drift.Context(Input, Output)

//pub fn restore_state(
//  options: mqtt.ConnectOptions(_),
//  state: String,
//) -> Result(State, String) {
//  session.from_json(state)
//  |> result.map(new(options, _))
//  |> result.map_error(string.inspect)
//}

pub fn new_state(options: mqtt.ConnectOptions(_)) -> State {
  new(options, session.new(False))
}

pub fn handle_input(context: Context, state: State, input: Input) -> Step {
  case input {
    Handle(event) ->
      case event {
        ReceivedData(data) -> receive(context, state, data)
        TransportEstablished -> transport_established(context, state)
        TransportFailed(error) -> disconnect_unexpectedly(context, state, error)
        TransportClosed -> transport_closed(context, state)
      }
    Perform(action) ->
      case action {
        SubscribeToUpdates(publish) ->
          subscribe_to_updates(context, state, publish)
        UnsubscribeFromUpdates(publish) ->
          unsubscribe_from_updates(context, state, publish)
        Connect(options, will) -> connect(context, state, options, will)
        Disconnect(complete) -> disconnect(context, state, complete)
        Subscribe(requests, effect) ->
          subscribe(context, state, requests, effect)
        Unsubscribe(topics, effect) ->
          unsubscribe(context, state, topics, effect)
        PublishMessage(data) -> publish(context, state, data)
        GetPendingPublishes(complete) ->
          get_pending_publishes(context, state, complete)
        WaitForPublishesToFinish(complete, timeout) ->
          wait_for_publishes(context, state, complete, timeout)
      }
    Timeout(action) -> handle_timer(context, state, action)
  }
}

//===== Privates =====//

fn new(options: mqtt.ConnectOptions(_), session: session.Session) -> State {
  let options =
    Options(
      client_id: options.client_id,
      authentication: convert.to_auth_options(options.authentication),
      keep_alive: options.keep_alive_seconds * 1000,
      server_timeout: options.server_timeout_ms,
    )
  State(
    options,
    session,
    NotConnected,
    dict.new(),
    dict.new(),
    None,
    None,
    None,
    set.new(),
    dict.new(),
  )
}

fn subscribe(
  context: Context,
  state: State,
  all_requests: List(SubscribeRequest),
  complete: Effect(OperationResult(List(Subscription))),
) -> Step {
  case all_requests, state.connection {
    [request, ..requests], Connected(_) -> {
      let #(session, id) = session.reserve_packet_id(state.session)

      let #(context, timer) =
        drift.start_timer(
          context,
          state.options.server_timeout,
          Timeout(SubscribeTimedOut(id)),
        )

      let pending_subs =
        dict.insert(
          state.pending_subs,
          id,
          PendingSubscription(all_requests, complete, timer),
        )

      context
      |> drift.output(
        send(outgoing.Subscribe(
          id,
          convert.to_packet_subscribe_request(request),
          list.map(requests, convert.to_packet_subscribe_request),
        )),
      )
      |> drift.continue(State(..state, session:, pending_subs:))
    }
    [], Connected(_) ->
      // Empty list is a no-op
      context
      |> drift.perform(SubscribeCompleted, complete, Ok([]))
      |> drift.continue(state)
    _, _ ->
      context
      |> drift.perform(SubscribeCompleted, complete, Error(mqtt.NotConnected))
      |> drift.continue(state)
  }
}

fn unsubscribe(
  context: Context,
  state: State,
  topics: List(String),
  complete: Effect(OperationResult(Nil)),
) -> Step {
  case topics, state.connection {
    [topic, ..topics], Connected(_) -> {
      let #(session, id) = session.reserve_packet_id(state.session)
      let #(context, timer) =
        drift.start_timer(
          context,
          state.options.server_timeout,
          Timeout(UnsubscribeTimedOut(id)),
        )
      let pending_unsubs =
        state.pending_unsubs
        |> dict.insert(id, PendingUnsubscribe(complete, timer))

      context
      |> drift.output(send(outgoing.Unsubscribe(id, topic, topics)))
      |> drift.continue(State(..state, session:, pending_unsubs:))
    }
    [], Connected(_) ->
      // Empty list is a no-op
      context
      |> drift.perform(UnsubscribeCompleted, complete, Ok(Nil))
      |> drift.continue(state)
    _, _ ->
      context
      |> drift.perform(UnsubscribeCompleted, complete, Error(mqtt.NotConnected))
      |> drift.continue(state)
  }
}

fn wait_for_publishes(
  context: Context,
  state: State,
  complete: Effect(OperationResult(Nil)),
  timeout: Int,
) -> Step {
  case session.pending_publishes(state.session) {
    0 ->
      context
      |> drift.perform(PublishesCompleted, complete, Ok(Nil))
      |> drift.continue(state)

    _ -> {
      let #(context, timer) =
        drift.start_timer(
          context,
          timeout,
          Timeout(WaitForPublishesTimeout(complete)),
        )
      let publish_completion_listeners =
        dict.insert(state.publish_completion_listeners, complete, timer)
      drift.continue(context, State(..state, publish_completion_listeners:))
    }
  }
}

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
    complete: Effect(OperationResult(List(Subscription))),
    timeout: Timer,
  )
}

type PendingUnsubscribe {
  PendingUnsubscribe(complete: Effect(OperationResult(Nil)), timeout: Timer)
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
    UnsubscribeTimedOut(id) -> time_out_unsubscribe(context, state, id)
  }
}

fn time_out_wait_for_publish(
  context: Context,
  state: State,
  complete: PublishCompletionEffect,
) -> Step {
  let publish_completion_listeners =
    dict.delete(state.publish_completion_listeners, complete)

  context
  |> drift.perform(PublishesCompleted, complete, Error(mqtt.OperationTimedOut))
  |> drift.continue(State(..state, publish_completion_listeners:))
}

fn time_out_subscription(context: Context, state: State, id: Int) -> Step {
  let pending_subs = state.pending_subs

  case dict.get(pending_subs, id) {
    // If the key was not found, it means that the suback
    // and timeout were queued to be handled at the same time.
    Error(_) -> drift.continue(context, state)
    Ok(PendingSubscription(_, complete, _)) ->
      kill_connection(
        drift.perform(
          context,
          SubscribeCompleted,
          complete,
          Error(mqtt.OperationTimedOut),
        ),
        State(..state, pending_subs: dict.delete(pending_subs, id)),
        "Subscribe timed out",
      )
  }
}

fn time_out_unsubscribe(context: Context, state: State, id: Int) -> Step {
  let pending_unsubs = state.pending_unsubs

  case dict.get(pending_unsubs, id) {
    // If the key was not found, it means that the unsuback
    // and timeout were queued to be handled at the same time.
    Error(_) -> drift.continue(context, state)
    Ok(PendingUnsubscribe(complete, _)) ->
      kill_connection(
        drift.perform(
          context,
          UnsubscribeCompleted,
          complete,
          Error(mqtt.OperationTimedOut),
        ),
        State(..state, pending_unsubs: dict.delete(pending_unsubs, id)),
        "Unsubscribe timed out",
      )
  }
}

fn subscribe_to_updates(
  context: Context,
  state: State,
  publish: Effect(mqtt.Update),
) -> Step {
  let update_listeners = set.insert(state.update_listeners, publish)
  drift.continue(context, State(..state, update_listeners:))
}

fn unsubscribe_from_updates(
  context: Context,
  state: State,
  publish: Effect(mqtt.Update),
) -> Step {
  let update_listeners = set.delete(state.update_listeners, publish)
  drift.continue(context, State(..state, update_listeners:))
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
        drift.start_timer(
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

fn disconnect(context: Context, state: State, complete: Effect(Nil)) -> Step {
  let outputs = case state.connection {
    Connecting(..) -> Some([CloseTransport])
    WaitingForConnAck(..) -> Some([CloseTransport])
    Connected(..) -> Some([send(outgoing.Disconnect), CloseTransport])
    Disconnecting -> None
    NotConnected -> None
  }

  let result = CompleteDisconnect(drift.bind_effect(complete, Nil))

  case outputs {
    Some(outputs) ->
      context
      |> drift.output_many(outputs)
      |> drift.output(result)
      |> drift.continue(State(..state, connection: Disconnecting))
    None ->
      context
      |> drift.output(result)
      |> drift.continue(state)
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
  complete: Effect(Int),
) -> Step {
  context
  |> drift.perform(
    ReturnPendingPublishes,
    complete,
    session.pending_publishes(state.session),
  )
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
    _ ->
      drift.stop_with_error(
        context,
        "Unexpected connection state when establishing transport: "
          <> case state.connection {
          Connected(..) -> "Connected"
          Connecting(..) -> "Connecting"
          Disconnecting -> "Disconnecting"
          NotConnected -> "Not connected"
          WaitingForConnAck(..) -> "Waiting for CONNACK"
        },
      )
  }
}

fn transport_closed(context: Context, state: State) -> Step {
  let change = case state.connection {
    Disconnecting -> mqtt.Disconnected
    _ -> mqtt.DisconnectedUnexpectedly("Transport closed")
  }

  context
  |> drift.cancel_all_timers()
  |> publish_update(state, ConnectionStateChanged(change))
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

  let context = case change {
    None -> context
    Some(change) ->
      context
      |> drift.output(CloseTransport)
      |> publish_update(state, ConnectionStateChanged(change))
  }

  context
  |> drift.cancel_all_timers()
  |> drift.continue(State(..state, connection: NotConnected))
}

fn receive(context: Context, state: State, data: BitArray) -> Step {
  case state.connection {
    WaitingForConnAck(connection) -> {
      case connection.receive_one(connection, data) {
        Error(e) ->
          kill_connection(
            context,
            state,
            "Received invalid data while connecting: " <> string.inspect(e),
          )
        Ok(#(connection, Some(packet))) -> {
          let step = handle_first_packet(context, state, connection, packet)

          // Process the rest of the data, if any
          use context, state <- drift.chain(step)
          receive(context, state, <<>>)
        }
        Ok(#(connection, None)) ->
          drift.continue(
            context,
            State(..state, connection: WaitingForConnAck(connection)),
          )
      }
    }

    Connected(connection) -> {
      case connection.receive_all(connection, data) {
        Error(e) ->
          kill_connection(
            context,
            state,
            "Received invalid data while connected: " <> string.inspect(e),
          )
        Ok(#(connection, packets)) -> {
          start_send_ping_timer(
            context,
            State(..state, connection: Connected(connection)),
          )
          |> handle_packets_while_connected(packets)
        }
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

fn handle_packets_while_connected(
  step: Step,
  packets: List(incoming.Packet),
) -> Step {
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
    incoming.UnsubAck(id) -> handle_unsuback(context, state, id)
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
          |> publish_update(state, update)
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
          |> publish_update(state, update)
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
      publish_update(
        context,
        state,
        mqtt.ReceivedMessage(msg.topic, msg.payload, msg.retain),
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
      |> drift.perform(SubscribeCompleted, pending_sub.complete, Ok(results))
      |> drift.continue(State(..state, pending_subs: dict.delete(subs, id))),
    )
  }

  case result {
    Error(e) -> kill_connection(context, state, e)
    Ok(step) -> step
  }
}

fn handle_unsuback(context: Context, state: State, id: Int) -> Step {
  let unsubs = state.pending_unsubs
  case dict.get(unsubs, id) {
    Ok(pending_unsub) -> {
      let #(context, _) = drift.cancel_timer(context, pending_unsub.timeout)
      context
      |> drift.perform(UnsubscribeCompleted, pending_unsub.complete, Ok(Nil))
      |> drift.continue(State(..state, pending_unsubs: dict.delete(unsubs, id)))
    }
    Error(_) ->
      kill_connection(
        context,
        state,
        "Received invalid packet id in unsubscribe ack",
      )
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
    drift.start_timer(context, state.options.keep_alive, Timeout(SendPing))

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
    drift.start_timer(
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
  result: OperationResult(Nil),
) -> Step {
  case session.pending_publishes(state.session) {
    0 -> {
      {
        use context, complete, timer <- dict.fold(
          state.publish_completion_listeners,
          context,
        )

        drift.cancel_timer(context, timer).0
        |> drift.perform(PublishesCompleted, complete, result)
      }
      |> drift.continue(
        State(..state, publish_completion_listeners: dict.new()),
      )
    }
    _ -> drift.continue(context, state)
  }
}

fn kill_connection(context: Context, state: State, error: String) -> Step {
  let sub_errors = {
    use pending_sub <- list.map(dict.values(state.pending_subs))
    SubscribeCompleted(drift.bind_effect(
      pending_sub.complete,
      Error(mqtt.ProtocolViolation),
    ))
  }

  let unsub_errors = {
    use pending_unsub <- list.map(dict.values(state.pending_unsubs))
    UnsubscribeCompleted(drift.bind_effect(
      pending_unsub.complete,
      Error(mqtt.ProtocolViolation),
    ))
  }

  context
  |> drift.cancel_all_timers()
  |> drift.output_many(sub_errors)
  |> drift.output_many(unsub_errors)
  |> drift.output(CloseTransport)
  |> publish_update(
    state,
    ConnectionStateChanged(mqtt.DisconnectedUnexpectedly(error)),
  )
  |> drift.continue(
    State(
      ..state,
      connection: NotConnected,
      pending_subs: dict.new(),
      pending_unsubs: dict.new(),
    ),
  )
}

fn send(packet: outgoing.Packet) -> Output {
  SendData(outgoing.encode_packet(packet))
}

fn publish_update(
  context: Context,
  state: State,
  update: mqtt.Update,
) -> Context {
  let updates = {
    use listener <- list.map(set.to_list(state.update_listeners))
    Publish(drift.bind_effect(listener, update))
  }
  drift.output_many(context, updates)
}

fn maybe_cancel_timer(context: Context, timer: Option(drift.Timer)) -> Context {
  case timer {
    Some(timer) -> drift.cancel_timer(context, timer).0
    None -> context
  }
}
