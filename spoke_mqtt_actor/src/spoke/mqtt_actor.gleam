import drift.{type EffectContext}
import drift/actor
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
  let publish = drift.new_effect(process.send(updates, _))
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
  actor.using_io(
    fn() { new_io(options.transport_options) },
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
    options: TransportOptions,
    socket: Option(Socket),
  )
}

fn new_io(options: TransportOptions) -> IoState {
  let self = process.new_subject()
  let tcp_selector = {
    use msg <- mug.select_tcp_messages(process.new_selector())
    case msg {
      mug.Packet(_, data) -> core.ReceivedData(data)
      mug.SocketClosed(_) -> core.TransportClosed
      mug.TcpError(_, error) -> core.TransportFailed(string.inspect(error))
    }
  }

  IoState(self, process.select(tcp_selector, self), options, None)
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
  let TcpOptions(host, port, timeout) = state.options
  case
    mug.connect(mug.ConnectionOptions(host, port, timeout, mug.Ipv6Preferred))
  {
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

fn close_transport(ctx: EffectContext(IoState)) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
  case state.socket {
    None -> state
    Some(socket) -> {
      // TODO Can we do anything with the error here?
      let _ = mug.shutdown(socket)
      process.send(state.self, core.TransportClosed)
      IoState(..state, socket: None)
    }
  }
}

fn send_data(
  ctx: EffectContext(IoState),
  data: BytesTree,
) -> EffectContext(IoState) {
  use state <- drift.use_effect_context(ctx)
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
