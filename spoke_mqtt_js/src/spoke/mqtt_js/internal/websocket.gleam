import gleam/bytes_tree.{type BytesTree}
import spoke/core.{
  ReceivedData, TransportClosed, TransportEstablished, TransportFailed,
}

pub type WebSocket

pub fn connect(url: String, send: fn(core.Input) -> Nil) -> WebSocket {
  connect_js(
    url,
    fn() { send(core.Handle(TransportEstablished)) },
    fn() { send(core.Handle(TransportClosed)) },
    fn(data) { send(core.Handle(ReceivedData(data))) },
    fn(error) { send(core.Handle(TransportFailed(error))) },
  )
}

pub fn send(socket: WebSocket, bytes: BytesTree) -> Result(Nil, String) {
  send_js(socket, bytes_tree.to_bit_array(bytes))
}

@external(javascript, "../spoke_mqtt_js.mjs", "close")
pub fn close(socket: WebSocket) -> Nil

@external(javascript, "../spoke_mqtt_js.mjs", "connect")
fn connect_js(
  url: String,
  on_open: fn() -> Nil,
  on_close: fn() -> Nil,
  on_message: fn(BitArray) -> Nil,
  on_error: fn(String) -> Nil,
) -> WebSocket

@external(javascript, "../spoke_mqtt_js.mjs", "send")
fn send_js(socket: WebSocket, data: BitArray) -> Result(Nil, String)
