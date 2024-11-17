import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process.{type Subject}

/// General abstraction over a data channel
/// Used internally for e.g. chunking and encoding/decoding
/// Note: only one call to start_receive is supported at the moment!
pub type Channel(s, r) {
  Channel(
    send: fn(s) -> ChannelResult(Nil),
    start_receive: fn(Receiver(r)) -> Nil,
    shutdown: fn() -> Nil,
  )
}

/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic)
pub type ByteChannel =
  Channel(BytesBuilder, BitArray)

pub type ChannelResult(a) =
  Result(a, ChannelError)

pub type Receiver(a) =
  Subject(ChannelResult(a))

pub type TransportOptions {
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
