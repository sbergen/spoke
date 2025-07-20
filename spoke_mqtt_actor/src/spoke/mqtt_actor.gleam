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
import spoke/core/ets_storage.{type EtsStorage}
import spoke/mqtt

pub opaque type Client {
  Client(
    self: Subject(core.Input),
    options: mqtt.ConnectOptions(TransportChannelConnector),
  )
}

/// If a session needs to be persisted across actor restarts
/// (either in supervision, or across node restarts),
/// the session needs to be stored in some persistent storage.
pub opaque type PersistentStorage {
  PersistToEts(storage: EtsStorage, filename: String)
}

/// Creates a new empty session that will be persisted to ETS in memory,
/// and can also be stored to a file.
pub fn persist_to_ets(filename: String) -> PersistentStorage {
  PersistToEts(ets_storage.new(), filename:)
}

/// Attempts to load a session that was previously stored in ETS and saved to a file.
pub fn load_ets_session_from_file(
  filename: String,
) -> Result(PersistentStorage, String) {
  case ets_storage.load_from_file(filename) {
    Error(e) -> Error(string.inspect(e))
    Ok(storage) -> Ok(PersistToEts(storage, filename))
  }
}

/// Stores the persisted session to a file.
/// Note that if the session is active and connected,
/// the result might not be valid.
/// However, this function is provided without checks in order to enable
/// storing to a file even if the actor is dead.
pub fn store_to_file(storage: PersistentStorage) -> Result(Nil, String) {
  ets_storage.store_to_file(storage.storage, storage.filename)
  |> result.map_error(string.inspect)
}

/// Frees the in-memory part of the persistent storage. 
/// Possible stored files need to be deleted separately.
pub fn delete_in_memory_storage(storage: PersistentStorage) {
  ets_storage.delete(storage.storage)
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

pub opaque type Builder {
  Builder(
    options: mqtt.ConnectOptions(TransportChannelConnector),
    state: core.State,
    storage: Option(PersistentStorage),
    init: Option(fn(Client) -> Nil),
    name: Option(process.Name(core.Input)),
  )
}

/// Starts building a new MQTT session, optionally using the given persistent storage.
pub fn new_session(
  options: mqtt.ConnectOptions(TransportChannelConnector),
  storage: Option(PersistentStorage),
) -> Builder {
  Builder(
    options:,
    state: core.new_state(options),
    storage:,
    init: None,
    name: None,
  )
}

/// Starts building an MQTT session restoring the state from the given persistent storage.
pub fn restore_session(
  options: mqtt.ConnectOptions(TransportChannelConnector),
  storage: PersistentStorage,
) -> Builder {
  let session_state = ets_storage.read(storage.storage)
  let state = core.restore_state(options, session_state)
  Builder(
    options: options,
    state:,
    storage: Some(storage),
    init: None,
    name: None,
  )
}

/// Use a named process and subject with the actor.
/// This allows using supervision, without invalidating previous instances of 
/// `Client`.
pub fn named(builder: Builder, name: process.Name(core.Input)) -> Builder {
  Builder(..builder, name: Some(name))
}

/// Run extra initialization after creating the actor.
/// Note that this runs in the actor process and contributes to the start timeout.
/// Sending a message to another process can be used to run the initialization
/// asynchronously.
pub fn with_extra_init(builder: Builder, init: fn(Client) -> Nil) -> Builder {
  Builder(..builder, init: Some(init))
}

/// Starts the actor with the given timeout (including the optional extra init).
/// Will not automatically connect to the server (see `connect`).
pub fn start(
  builder: Builder,
  timeout: Int,
) -> Result(otp_actor.Started(Client), otp_actor.StartError) {
  new_io_driver(builder.options, builder.storage)
  |> actor.with_stepper(builder.state, core.handle_input)
  |> actor.start(timeout, fn(subject) {
    let client = Client(subject, builder.options)
    case builder.init {
      Some(init) -> init(client)
      None -> Nil
    }
    client
  })
}

/// A handle for update subscriptions
pub opaque type UpdateSubscription {
  UpdateSubscription(effect: drift.Effect(mqtt.Update))
}

/// Will start publishing client updates to the given subject.
pub fn subscribe_to_updates(
  client: Client,
  updates: Subject(mqtt.Update),
) -> UpdateSubscription {
  let publish = drift.new_effect(process.send(updates, _))
  process.send(client.self, Perform(SubscribeToUpdates(publish)))
  UpdateSubscription(publish)
}

/// Stops publishing client updates associated to the subscription.
pub fn unsubscribe_from_updates(
  client: Client,
  subscription: UpdateSubscription,
) -> Nil {
  process.send(
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
  process.send(client.self, Perform(Connect(clean_session, will)))
}

/// Disconnects from the MQTT server.
/// The connection state change will also be published as an update.
/// If a connection is not established or being established,
/// this will be a no-op.
/// Returns the serialized session state to be potentially restored later.
pub fn disconnect(client: Client) -> Nil {
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

/// Returns the number of QoS > 0 publishes that haven't yet been completely published.
/// Also see `wait_for_publishes_to_finish`.
pub fn pending_publishes(client: Client) -> Int {
  use effect <- actor.call(client.self, 2 * client.options.server_timeout_ms)
  Perform(GetPendingPublishes(effect))
}

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

fn new_io_driver(
  options: mqtt.ConnectOptions(TransportChannelConnector),
  storage: Option(PersistentStorage),
) {
  actor.using_io(
    fn() {
      let self = process.new_subject()
      let selector = process.new_selector() |> process.select(self)
      IoState(
        self:,
        selector:,
        connector: options.transport_options,
        channel: None,
        storage:,
      )
    },
    fn(io_state) { io_state.selector },
    handle_output,
  )
}

type IoState {
  IoState(
    self: Subject(core.Input),
    selector: Selector(core.Input),
    connector: TransportChannelConnector,
    channel: Option(TransportChannel),
    storage: Option(PersistentStorage),
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
    core.ReturnPendingPublishes(action) -> drift.perform_effect(ctx, action)
    core.CompleteDisconnect(action) -> drift.perform_effect(ctx, action)
    core.UpdatePersistedSession(update) -> {
      use state <- drift.use_effect_context(ctx)
      case state.storage {
        None -> Nil
        Some(PersistToEts(storage, _)) -> ets_storage.update(storage, update)
      }

      state
    }
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
