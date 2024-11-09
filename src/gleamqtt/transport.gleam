import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process.{type Subject}

/// General abstraction over a data channel
/// User internally for e.g. chunking and encoding/decoding
pub type Channel(s, r) {
  Channel(
    send: fn(s) -> Result(Nil, ChannelError),
    start_receive: fn(Receiver(r)) -> Nil,
  )
}

/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic)
pub type ByteChannel =
  Channel(BytesBuilder, BitArray)

pub type Receiver(r) =
  Subject(Result(r, ChannelError))

pub type ChannelOptions {
  TcpOptions(host: String, port: Int, connect_timeout: Int, send_timeout: Int)
}

/// Generic error type for channels.
/// Will need to refine the errors later...
pub type ChannelError {
  ChannelClosed
  ConnectFailed(String)
  TransportError(String)
  SendFailed(String)
  InvalidData(String)
}
