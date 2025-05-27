import drift/actor
import drift/effect
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/result
import gleam/string
import mug.{type Socket}
import spoke/core.{Connect, Perform, Subscribe, SubscribeToUpdates}
import spoke/mqtt

pub opaque type Client {
  Client(
    self: Subject(core.Input),
    options: mqtt.ConnectOptions(TransportOptions),
  )
}

pub opaque type TransportOptions {
  TcpOptions(host: String, port: Int, connect_timeout: Int)
}

pub fn using_tcp(
  host host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
) -> TransportOptions {
  TcpOptions(host, port, connect_timeout)
}

// TODO: Better error types below:

pub fn start_session(
  options: mqtt.ConnectOptions(TransportOptions),
) -> Result(Client, otp_actor.StartError) {
  from_state(options, core.new_state(options))
}

pub fn restore_session(
  options: mqtt.ConnectOptions(TransportOptions),
  state: String,
) -> Result(Client, otp_actor.StartError) {
  core.restore_state(options, state)
  |> result.map_error(otp_actor.InitFailed)
  |> result.then(from_state(options, _))
}

// END TODO

pub fn subscribe_to_updates(client: Client) -> Subject(mqtt.Update) {
  let updates = process.new_subject()
  let publish = effect.from(process.send(updates, _))
  process.send(client.self, Perform(SubscribeToUpdates(publish)))
  updates
}

pub fn connect(
  client: Client,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Nil {
  process.send(client.self, Perform(Connect(clean_session, will)))
}

pub fn subscribe(
  client: Client,
  requests: List(mqtt.SubscribeRequest),
) -> Result(List(mqtt.Subscription), mqtt.OperationError) {
  use effect <- actor.call(client.self, 2 * client.options.server_timeout_ms)
  Perform(Subscribe(requests, effect))
}

// TODO: Add more wrappers

//===== Privates =====/

fn from_state(
  options: mqtt.ConnectOptions(TransportOptions),
  state: core.State,
) -> Result(Client, otp_actor.StartError) {
  actor.using_io(fn() { new_io(options.transport_options) }, handle_output)
  |> actor.start(1000, state, core.handle_input)
  |> result.map(Client(_, options))
}

type IoState {
  IoState(
    self: Subject(core.Input),
    options: TransportOptions,
    socket: Option(Socket),
  )
}

fn new_io(options: TransportOptions) -> #(IoState, Selector(core.Input)) {
  let self = process.new_subject()
  let tcp_selector = {
    use msg <- mug.selecting_tcp_messages(process.new_selector())
    case msg {
      mug.Packet(_, data) -> core.ReceivedData(data)
      mug.SocketClosed(_) -> core.TransportClosed
      mug.TcpError(_, error) -> core.TransportFailed(string.inspect(error))
    }
  }
  #(IoState(self, options, None), process.select(tcp_selector, self))
}

fn handle_output(
  ctx: effect.Context(IoState, Selector(core.Input)),
  output: core.Output,
) -> Result(effect.Context(IoState, Selector(core.Input)), a) {
  Ok(case output {
    core.OpenTransport -> open_transport(ctx)
    core.CloseTransport -> close_transport(ctx)
    core.SendData(data) -> send_data(ctx, data)
    core.Publish(action) -> effect.perform(ctx, action)
    core.PublishesCompleted(action) -> effect.perform(ctx, action)
    core.SubscribeCompleted(action) -> effect.perform(ctx, action)
    core.UnsubscribeCompleted(action) -> effect.perform(ctx, action)
    core.ReportStateAtDisconnect(action) -> effect.perform(ctx, action)
    core.ReturnPendingPublishes(action) -> effect.perform(ctx, action)
  })
}

fn open_transport(
  ctx: effect.Context(IoState, Selector(core.Input)),
) -> effect.Context(IoState, Selector(core.Input)) {
  use state <- effect.map_context(ctx)
  let TcpOptions(host, port, timeout) = state.options
  case mug.connect(mug.ConnectionOptions(host, port, timeout)) {
    Ok(socket) -> {
      mug.receive_all_packets_as_messages(socket)
      process.send(state.self, core.TransportEstablished)
      IoState(..state, socket: Some(socket))
    }
    Error(e) -> {
      process.send(state.self, core.TransportFailed(string.inspect(e)))
      state
    }
  }
}

fn close_transport(
  ctx: effect.Context(IoState, Selector(core.Input)),
) -> effect.Context(IoState, Selector(core.Input)) {
  use state <- effect.map_context(ctx)
  case state.socket {
    None -> state
    Some(socket) -> {
      // TODO Can we do anything with the error here?
      let _ = mug.shutdown(socket)
      IoState(..state, socket: None)
    }
  }
}

fn send_data(
  ctx: effect.Context(IoState, Selector(core.Input)),
  data: BytesTree,
) -> effect.Context(IoState, Selector(core.Input)) {
  use state <- effect.map_context(ctx)
  case state.socket {
    None -> {
      process.send(state.self, core.TransportFailed("Not connected"))
      state
    }
    Some(socket) ->
      case mug.send_builder(socket, data) {
        Error(error) -> {
          process.send(
            state.self,
            core.TransportFailed("Send failed: " <> string.inspect(error)),
          )
          IoState(..state, socket: None)
        }
        Ok(_) -> state
      }
  }
}
