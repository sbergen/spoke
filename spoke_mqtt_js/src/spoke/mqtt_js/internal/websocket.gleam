import gleam/bytes_tree.{type BytesTree}

pub type WebSocket

pub fn connect(
  host: String,
  port: Int,
  timeout: Int,
) -> Result(WebSocket, String) {
  todo
}

pub fn send(socket: WebSocket, bytes: BytesTree) -> Result(Nil, String) {
  todo
}

pub fn close(socket: WebSocket) -> Nil {
  todo
}
