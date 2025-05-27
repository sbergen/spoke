import gleam/bytes_tree.{type BytesTree}
import gleam/string
import spoke/core

pub type WebSocket

pub fn connect(
  host: String,
  port: Int,
  _timeout: Int,
  send: fn(core.Input) -> Nil,
) -> Result(WebSocket, String) {
  let url = "ws://" <> host <> ":" <> string.inspect(port)
  Ok(
    connect_js(url, fn() { send(core.TransportEstablished) }, fn(data) {
      send(core.ReceivedData(data))
    }),
  )
}

pub fn send(socket: WebSocket, bytes: BytesTree) -> Result(Nil, String) {
  Ok(send_js(socket, bytes_tree.to_bit_array(bytes)))
}

pub fn close(socket: WebSocket) -> Nil {
  todo
}

@external(javascript, "../spoke_mqtt_js.mjs", "connect")
fn connect_js(
  url: String,
  on_open: fn() -> Nil,
  on_message: fn(BitArray) -> Nil,
) -> WebSocket

@external(javascript, "../spoke_mqtt_js.mjs", "send")
fn send_js(socket: WebSocket, data: BitArray) -> Nil
