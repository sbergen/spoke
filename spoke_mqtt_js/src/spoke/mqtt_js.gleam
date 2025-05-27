import drift/effect
import drift/js/runtime.{type Runtime}
import gleam/bytes_tree.{type BytesTree}
import gleam/option.{type Option, None, Some}
import gleam/string
import spoke/core
import spoke/mqtt
import spoke/mqtt_js/internal/websocket

pub opaque type Client {
  Client(
    self: Runtime(core.Input),
    options: mqtt.ConnectOptions(TransportOptions),
  )
}

pub opaque type TransportOptions {
  WebsocketOptions(host: String, port: Int, connect_timeout: Int)
}

pub fn using_websocket(
  host: String,
  port: Int,
  connect_timeout: Int,
) -> TransportOptions {
  WebsocketOptions(host, port, connect_timeout)
}

pub fn start_session(options: mqtt.ConnectOptions(TransportOptions)) -> Client {
  from_state(options, core.new_state(options))
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
  ctx: effect.Context(IoState, Nil),
  output: core.Output,
  send: fn(core.Input) -> Nil,
) -> Result(effect.Context(IoState, Nil), a) {
  Ok(case output {
    core.OpenTransport -> open_transport(ctx, send)
    core.CloseTransport -> close_transport(ctx, send)
    core.SendData(data) -> send_data(ctx, data, send)
    core.Publish(action) -> effect.perform(ctx, action)
    core.PublishesCompleted(action) -> effect.perform(ctx, action)
    core.SubscribeCompleted(action) -> effect.perform(ctx, action)
    core.UnsubscribeCompleted(action) -> effect.perform(ctx, action)
    core.ReportStateAtDisconnect(action) -> effect.perform(ctx, action)
    core.ReturnPendingPublishes(action) -> effect.perform(ctx, action)
  })
}

fn open_transport(
  ctx: effect.Context(IoState, Nil),
  send: fn(core.Input) -> Nil,
) -> effect.Context(IoState, Nil) {
  use state <- effect.map_context(ctx)
  let WebsocketOptions(host, port, timeout) = state.options
  case websocket.connect(host, port, timeout) {
    Ok(socket) -> {
      send(core.TransportEstablished)
      IoState(..state, socket: Some(socket))
    }
    Error(e) -> {
      send(core.TransportFailed(string.inspect(e)))
      state
    }
  }
}

fn close_transport(
  ctx: effect.Context(IoState, Nil),
  send: fn(core.Input) -> Nil,
) -> effect.Context(IoState, Nil) {
  use state <- effect.map_context(ctx)
  case state.socket {
    None -> state
    Some(socket) -> {
      websocket.close(socket)
      send(core.TransportClosed)
      IoState(..state, socket: None)
    }
  }
}

fn send_data(
  ctx: effect.Context(IoState, Nil),
  data: BytesTree,
  send: fn(core.Input) -> Nil,
) -> effect.Context(IoState, Nil) {
  use state <- effect.map_context(ctx)
  case state.socket {
    None -> {
      send(core.TransportFailed("Not connected"))
      state
    }
    Some(socket) ->
      case websocket.send(socket, data) {
        Error(error) -> {
          send(core.TransportFailed("Send failed: " <> error))
          IoState(..state, socket: None)
        }
        Ok(_) -> state
      }
  }
}
