import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process.{type Subject}

// TODO, make this generic to keep EncodedChannel in sync?
/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic)
pub type Channel {
  Channel(
    send: fn(BytesBuilder) -> Result(Nil, ChannelError),
    start_receive: fn(Receiver) -> Nil,
  )
}

pub type Receiver =
  Subject(Result(BitArray, ChannelError))

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
}