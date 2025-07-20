import drift/js/channel.{type Channel}

pub type WebSocketServer {
  WebSocketServer(
    connections: Channel(fn(BitArray) -> Nil),
    messages: Channel(BitArray),
    closes: Channel(Nil),
    shut_down: fn() -> Nil,
  )
}

pub fn start(port: Int) -> WebSocketServer {
  let connections = channel.new()
  let messages = channel.new()
  let closes = channel.new()

  let shut_down =
    start_js(
      port,
      channel.send(connections, _),
      channel.send(messages, _),
      fn() { channel.send(closes, Nil) },
    )

  WebSocketServer(connections:, messages:, closes:, shut_down:)
}

@external(javascript, "./websocket_server_ffi.mjs", "start")
fn start_js(
  port: Int,
  on_connected: fn(fn(BitArray) -> Nil) -> Nil,
  on_message: fn(BitArray) -> Nil,
  on_close: fn() -> Nil,
) -> fn() -> Nil
