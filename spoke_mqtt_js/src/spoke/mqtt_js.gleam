import drift.{type EffectContext}
import drift/js/channel.{type Channel}
import drift/js/runtime.{type Runtime}
import gleam/bytes_tree.{type BytesTree}
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import spoke/core.{
  Connect, Disconnect, GetPendingPublishes, Perform, PublishMessage, Subscribe,
  SubscribeToUpdates, TransportFailed, Unsubscribe, WaitForPublishesToFinish,
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

/// Creates transport options for communicating with a MQTT server over a WebSocket.
pub fn using_websocket(url: String) -> TransportOptions {
  WebsocketOptions(url)
}

/// Starts a new MQTT session with the given options.
/// Does not automatically connect to the server.
pub fn start_session(options: mqtt.ConnectOptions(TransportOptions)) -> Client {
  from_state(options, core.new_state(options))
}

/// A handle for update subscriptions
pub opaque type UpdateSubscription {
  UpdateSubscription(effect: drift.Effect(mqtt.Update))
}

/// Returns a channel that publishes client updates.
pub fn subscribe_to_updates(
  client: Client,
) -> #(Channel(mqtt.Update), UpdateSubscription) {
  let channel = channel.new()
  let subscription = register_update_callback(client, channel.send(channel, _))
  #(channel, subscription)
}

/// Registers a callback to be executed on every client update. 
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

/// Starts connecting to the MQTT server.
/// The connection state will be published as an update.
/// If a connection is already established or being established,
/// this will be a no-op.
/// Note that switching between `clean_session` values
/// while already connecting is currently not well handled.
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
  use effect <- call(client)
  Perform(Disconnect(effect))
}

/// Subscribes to the given topics.
/// The returned promise will resolve when we get a response from the server,
/// returning the result of the operation.
pub fn subscribe(
  client: Client,
  requests: List(mqtt.SubscribeRequest),
) -> Promise(Result(List(mqtt.Subscription), mqtt.OperationError)) {
  {
    use effect <- call(client)
    Perform(Subscribe(requests, effect))
  }
  |> promise.map(result.flatten)
}

/// Unsubscribes from the given topics.
/// The returned promise will resolve when we get a response from the server,
/// returning the result of the operation.
pub fn unsubscribe(
  client: Client,
  topics: List(String),
) -> Promise(Result(Nil, mqtt.OperationError)) {
  {
    use effect <- call(client)
    Perform(Unsubscribe(topics, effect))
  }
  |> promise.map(result.flatten)
}

/// Publishes a new message, which will be sent to the sever.
/// If not connected, Qos 0 messages will be dropped,
/// and higher QoS level messages will be sent once connected.
pub fn publish(client: Client, data: mqtt.PublishData) -> Nil {
  runtime.send(client.self, Perform(PublishMessage(data)))
}

/// Returns the number of QoS > 0 publishes that haven't yet been completely published.
/// Also see `wait_for_publishes_to_finish`.
pub fn pending_publishes(
  client: Client,
) -> Promise(Result(Int, mqtt.OperationError)) {
  use effect <- call(client)
  Perform(GetPendingPublishes(effect))
}

/// Wait for all pending QoS > 0 publishes to complete.
/// Returns an error if the operation times out,
/// or if the client is killed while waiting.
pub fn wait_for_publishes_to_finish(
  client: Client,
  timeout: Int,
) -> Promise(Result(Nil, mqtt.OperationError)) {
  {
    use effect <- call(client)
    Perform(WaitForPublishesToFinish(effect, timeout))
  }
  |> promise.map(result.flatten)
}

//===== Privates =====/

fn call(
  client: Client,
  with: fn(drift.Effect(a)) -> core.Input,
) -> Promise(Result(a, mqtt.OperationError)) {
  use result <- promise.map({
    use effect <- runtime.call_forever(client.self)
    with(effect)
  })

  result
  |> result.map_error(fn(e) { mqtt.ClientRuntimeError(string.inspect(e)) })
}

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
