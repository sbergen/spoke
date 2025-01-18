import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/result
import gleam/string
import mug
import spoke/internal/transport.{type ByteChannel}

pub fn connect(
  host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
) -> Result(ByteChannel, String) {
  let options = mug.ConnectionOptions(host, port, connect_timeout)
  use socket <- result.try(
    mug.connect(options) |> map_mug_error("Connect error"),
  )

  let selector =
    process.new_selector()
    |> mug.selecting_tcp_messages(map_tcp_message)

  Ok(
    transport.ByteChannel(
      send: send(socket, _),
      selecting_next: fn() {
        mug.receive_next_packet_as_message(socket)
        selector
      },
      shutdown: fn() {
        // Nothing to do if this fails
        let _ = mug.shutdown(socket)
        Nil
      },
    ),
  )
}

fn send(socket: mug.Socket, data: BytesTree) -> Result(Nil, String) {
  mug.send_builder(socket, data)
  |> map_mug_error("Send error")
}

fn map_tcp_message(msg: mug.TcpMessage) -> Result(BitArray, String) {
  case msg {
    mug.Packet(_, data) -> Ok(data)
    mug.SocketClosed(_) -> Error("Channel closed")
    mug.TcpError(_, e) -> Error("TCP error: " <> string.inspect(e))
  }
}

fn map_mug_error(r: Result(a, mug.Error), reason: String) -> Result(a, String) {
  result.map_error(r, fn(e) { reason <> ": " <> string.inspect(e) })
}
