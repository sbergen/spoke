import drift.{type EffectContext}
import drift/actor
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/result
import gleam/string
import spoke/core.{
  Connect, Disconnect, GetPendingPublishes, Perform, PublishMessage, Subscribe,
  SubscribeToUpdates, TransportFailed, Unsubscribe, WaitForPublishesToFinish,
}
import spoke/mqtt

pub opaque type Client {
  Client(
    self: Subject(core.Input),
    options: mqtt.ConnectOptions(TransportChannelConnector),
  )
}

/// Provides the abstraction over a transport channel,
/// e.g. TCP or WebSocket.
pub type TransportChannel {
  TransportChannel(
    events: Selector(core.TransportEvent),
    send: fn(BytesTree) -> Result(Nil, String),
    close: fn() -> Result(Nil, String),
  )
}

pub type TransportChannelConnector =
  fn() -> Result(TransportChannel, String)

// TODO: Better error types below:

pub fn start_session(
  options: mqtt.ConnectOptions(TransportChannelConnector),
) -> Result(Client, otp_actor.StartError) {
  from_state(options, core.new_state(options))
}

pub fn restore_session(
  options: mqtt.ConnectOptions(TransportChannelConnector),
  state: String,
) -> Result(Client, otp_actor.StartError) {
  core.restore_state(options, state)
  |> result.map_error(otp_actor.InitFailed)
  |> result.try(from_state(options, _))
}

// END TODO

/// Will start publishing client updates to the given subject.
pub fn subscribe_to_updates(
  client: Client,
  updates: Subject(mqtt.Update),
) -> Nil {
  let publish = drift.new_effect(process.send(updates, _))
  process.send(client.self, Perform(SubscribeToUpdates(publish)))
}

// TODO: Add a method for unsubscribing from updates

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
  process.send(client.self, Perform(Connect(clean_session, will)))
}

/// Disconnects from the MQTT server.
/// The connection state change will also be published as an update.
/// If a connection is not established or being established,
/// this will be a no-op.
/// Returns the serialized session state to be potentially restored later.
pub fn disconnect(client: Client) -> String {
  use effect <- actor.call(client.self, 2 * client.options.server_timeout_ms)
  Perform(Disconnect(effect))
}

/// Publishes a new message, which will be sent to the sever.
/// If not connected, Qos 0 messages will be dropped,
/// and higher QoS level messages will be sent once connected.
pub fn publish(client: Client, data: mqtt.PublishData) -> Nil {
  process.send(client.self, Perform(PublishMessage(data)))
}

/// Subscribes to the given topics.
/// Will block until we get a response from the server,
/// returning the result of the operation.
pub fn subscribe(
  client: Client,
  requests: List(mqtt.SubscribeRequest),
) -> Result(List(mqtt.Subscription), mqtt.OperationError) {
  use effect <- actor.call(client.self, 2 * client.options.server_timeout_ms)
  Perform(Subscribe(requests, effect))
}

/// Unsubscribes from the given topics.
/// Will block until we get a response from the server,
/// returning the result of the operation.
pub fn unsubscribe(
  client: Client,
  topics: List(String),
) -> Result(Nil, mqtt.OperationError) {
  use effect <- actor.call(client.self, 2 * client.options.server_timeout_ms)
  Perform(Unsubscribe(topics, effect))
}

// TODO: test
/// Returns the number of QoS > 0 publishes that haven't yet been completely published.
/// Also see `wait_for_publishes_to_finish`.
pub fn pending_publishes(client: Client) -> Int {
  use effect <- actor.call(client.self, 2 * client.options.server_timeout_ms)
  Perform(GetPendingPublishes(effect))
}

// TODO: test
/// Wait for all pending QoS > 0 publishes to complete.
/// Returns an error if the operation times out,
/// or panics if the client is killed while waiting.
pub fn wait_for_publishes_to_finish(
  client: Client,
  timeout: Int,
) -> Result(Nil, mqtt.OperationError) {
  use effect <- actor.call_forever(client.self)
  Perform(WaitForPublishesToFinish(effect, timeout))
}

//===== Privates =====/

fn from_state(
  options: mqtt.ConnectOptions(TransportChannelConnector),
  state: core.State,
) -> Result(Client, otp_actor.StartError) {
  actor.using_io(
    fn() {
      let self = process.new_subject()
      let selector = process.new_selector() |> process.select(self)
      IoState(self, selector, options.transport_options, None)
    },
    fn(io_state) { io_state.selector },
    handle_output,
  )
  |> actor.start(1000, state, core.handle_input)
  |> result.map(Client(_, options))
}

type IoState {
  IoState(
    self: Subject(core.Input),
    selector: Selector(core.Input),
    connector: TransportChannelConnector,
    channel: Option(TransportChannel),
  )
}

fn handle_output(
  ctx: EffectContext(IoState),
  output: core.Output,
) -> Result(EffectContext(IoState), a) {
  Ok(case output {
    core.OpenTransport -> open_transport(ctx)
    core.CloseTransport -> close_transport(ctx)
    core.SendData(data) -> send_data(ctx, data)
    core.Publish(action) -> drift.perform_effect(ctx, action)
    core.PublishesCompleted(action) -> drift.perform_effect(ctx, action)
    core.SubscribeCompleted(action) -> drift.perform_effect(ctx, action)
    core.UnsubscribeCompleted(action) -> drift.perform_effect(ctx, action)
    core.ReportStateAtDisconnect(action) -> drift.perform_effect(ctx, action)
    core.ReturnPendingPublishes(action) -> drift.perform_effect(ctx, action)
  })
}

fn open_transport(ctx: EffectContext(IoState)) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  case state.connector() {
    Ok(channel) -> {
      let selector =
        channel.events
        |> process.map_selector(core.Handle)
        |> process.select(state.self)
      IoState(..state, selector:, channel: Some(channel))
    }
    Error(e) -> {
      process.send(state.self, core.Handle(TransportFailed(string.inspect(e))))
      state
    }
  }
}

fn close_transport(ctx: EffectContext(IoState)) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  case state.channel {
    None -> state
    Some(channel) -> {
      case channel.close() {
        Ok(_) -> Nil
        Error(e) -> process.send(state.self, core.Handle(TransportFailed(e)))
      }

      IoState(..state, channel: None)
    }
  }
}

fn send_data(
  ctx: EffectContext(IoState),
  data: BytesTree,
) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  case state.channel {
    None -> {
      process.send(state.self, core.Handle(TransportFailed("Not connected")))
      state
    }
    Some(channel) ->
      case channel.send(data) {
        Error(error) -> {
          process.send(
            state.self,
            core.Handle(TransportFailed(
              "Send failed: " <> string.inspect(error),
            )),
          )

          // Close the channel, just in case. Ignore errors.
          let _ = channel.close()
          IoState(..state, channel: None)
        }
        Ok(_) -> state
      }
  }
}
