import drift.{type EffectContext}
import drift/js/channel.{type Channel}
import drift/js/runtime.{type Runtime}
import gleam/bytes_tree.{type BytesTree}
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import spoke/core.{
  Connect, Disconnect, Perform, PublishMessage, Subscribe, SubscribeToUpdates,
  TransportFailed,
}
import spoke/mqtt
import spoke/mqtt_js/internal/websocket

pub opaque type Client {
  Client(
    self: Runtime(core.Input),
    options: mqtt.ConnectOptions(TransportOptions),
  )
}

pub opaque type TransportOptions {
  WebsocketOptions(url: String)
}

pub fn using_websocket(url: String) -> TransportOptions {
  WebsocketOptions(url)
}

pub fn start_session(options: mqtt.ConnectOptions(TransportOptions)) -> Client {
  from_state(options, core.new_state(options))
}

/// A handle for update subscriptions
pub opaque type UpdateSubscription {
  UpdateSubscription(effect: drift.Effect(mqtt.Update))
}

pub fn subscribe_to_updates(
  client: Client,
) -> #(Channel(mqtt.Update), UpdateSubscription) {
  let channel = channel.new()
  let subscription = register_update_callback(client, channel.send(channel, _))
  #(channel, subscription)
}

pub fn register_update_callback(
  client: Client,
  callback: fn(mqtt.Update) -> Nil,
) -> UpdateSubscription {
  let publish = drift.new_effect(callback)
  runtime.send(client.self, Perform(SubscribeToUpdates(publish)))
  UpdateSubscription(publish)
}

/// Stops publishing client updates associated to the subscription.
pub fn unsubscribe_from_updates(
  client: Client,
  subscription: UpdateSubscription,
) -> Nil {
  runtime.send(
    client.self,
    Perform(core.UnsubscribeFromUpdates(subscription.effect)),
  )
}

pub fn connect(
  client: Client,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Nil {
  runtime.send(client.self, Perform(Connect(clean_session, will)))
}

/// Disconnects from the MQTT server.
/// The connection state change will also be published as an update.
/// If a connection is not established or being established,
/// this will be a no-op.
/// Returns the serialized session state to be potentially restored later.
pub fn disconnect(client: Client) -> Promise(Result(Nil, mqtt.OperationError)) {
  use result <- promise.map({
    use effect <- runtime.call(
      client.self,
      2 * client.options.server_timeout_ms,
    )
    Perform(Disconnect(effect))
  })

  result
  |> result.map_error(fn(e) { mqtt.ClientRuntimeError(string.inspect(e)) })
}

pub fn subscribe(
  client: Client,
  requests: List(mqtt.SubscribeRequest),
) -> Promise(Result(List(mqtt.Subscription), mqtt.OperationError)) {
  use result <- promise.map({
    use effect <- runtime.call(
      client.self,
      2 * client.options.server_timeout_ms,
    )
    Perform(Subscribe(requests, effect))
  })

  result
  |> result.map_error(fn(e) { mqtt.ClientRuntimeError(string.inspect(e)) })
  |> result.flatten
}

/// Publishes a new message, which will be sent to the sever.
/// If not connected, Qos 0 messages will be dropped,
/// and higher QoS level messages will be sent once connected.
pub fn publish(client: Client, data: mqtt.PublishData) -> Nil {
  runtime.send(client.self, Perform(PublishMessage(data)))
}

//===== Privates =====/

fn from_state(
  options: mqtt.ConnectOptions(TransportOptions),
  state: core.State,
) -> Client {
  let #(_completion, runtime) =
    runtime.start(
      state,
      fn(_) { IoState(options.transport_options, None) },
      core.handle_input,
      handle_output,
    )
  Client(runtime, options)
}

type IoState {
  IoState(options: TransportOptions, socket: Option(websocket.WebSocket))
}

fn handle_output(
  ctx: EffectContext(IoState),
  output: core.Output,
  send: fn(core.Input) -> Nil,
) -> Result(EffectContext(IoState), a) {
  Ok(case output {
    core.OpenTransport -> open_transport(ctx, send)
    core.CloseTransport -> close_transport(ctx)
    core.SendData(data) -> send_data(ctx, data, send)
    core.Publish(action) -> drift.perform_effect(ctx, action)
    core.PublishesCompleted(action) -> drift.perform_effect(ctx, action)
    core.SubscribeCompleted(action) -> drift.perform_effect(ctx, action)
    core.UnsubscribeCompleted(action) -> drift.perform_effect(ctx, action)
    core.ReturnPendingPublishes(action) -> drift.perform_effect(ctx, action)
    core.CompleteDisconnect(action) -> drift.perform_effect(ctx, action)
    core.UpdatePersistedSession(_) -> {
      // We don't have session persistence yet.
      ctx
    }
  })
}

fn open_transport(
  ctx: EffectContext(IoState),
  send: fn(core.Input) -> Nil,
) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  let WebsocketOptions(url) = state.options
  let socket = websocket.connect(url, send)
  IoState(..state, socket: Some(socket))
}

fn close_transport(ctx: EffectContext(IoState)) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  case state.socket {
    None -> state
    Some(socket) -> {
      websocket.close(socket)
      IoState(..state, socket: None)
    }
  }
}

fn send_data(
  ctx: EffectContext(IoState),
  data: BytesTree,
  send: fn(core.Input) -> Nil,
) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  case state.socket {
    None -> {
      send(core.Handle(TransportFailed("Not connected")))
      state
    }
    Some(socket) ->
      case websocket.send(socket, data) {
        Error(error) -> {
          send(core.Handle(TransportFailed("Send failed: " <> error)))
          IoState(..state, socket: None)
        }
        Ok(_) -> state
      }
  }
}
