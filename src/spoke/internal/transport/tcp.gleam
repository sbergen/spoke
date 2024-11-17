import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process
import gleam/result
import gleam/string
import mug
import spoke/internal/transport.{
  type ByteChannel, type ChannelError, type ChannelResult,
}

pub fn connect(
  host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
) -> ChannelResult(ByteChannel) {
  let options = mug.ConnectionOptions(host, port, connect_timeout)
  use socket <- result.try(
    mug.connect(options) |> map_mug_error(transport.ConnectFailed),
  )

  mug.receive_next_packet_as_message(socket)
  let selector =
    process.new_selector()
    |> mug.selecting_tcp_messages(map_tcp_message(socket, _))

  Ok(
    transport.Channel(
      send: send(socket, _),
      selecting_next: fn(_) { selector },
      shutdown: fn() {
        // TODO, should I check the result?
        let _ = mug.shutdown(socket)
        Nil
      },
    ),
  )
}

fn send(socket: mug.Socket, data: BytesBuilder) -> ChannelResult(Nil) {
  mug.send_builder(socket, data)
  |> map_mug_error(transport.SendFailed)
}

fn map_tcp_message(
  socket: mug.Socket,
  msg: mug.TcpMessage,
) -> #(Nil, ChannelResult(BitArray)) {
  let result = case msg {
    mug.Packet(_, data) -> {
      mug.receive_next_packet_as_message(socket)
      Ok(data)
    }
    mug.SocketClosed(_) -> Error(transport.ChannelClosed)
    mug.TcpError(_, e) -> Error(transport.TransportError(string.inspect(e)))
  }

  #(Nil, result)
}

fn map_mug_error(
  r: Result(a, mug.Error),
  ctor: fn(String) -> ChannelError,
) -> ChannelResult(a) {
  result.map_error(r, fn(e) { ctor(string.inspect(e)) })
}
