import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process.{type Subject}

/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic)
pub type Channel {
  Channel(
    send: fn(BytesBuilder) -> Result(Nil, ChannelError),
    receive: Subject(IncomingData),
    // TODO: Add shutdown
  )
}

pub type ChannelOptions {
  TcpOptions(host: String, port: Int, connect_timeout: Int, send_timeout: Int)
}

/// Generic error type for channels.
/// Will need to refine the errors later...
pub type ChannelError {
  ConnectFailed(String)
  TransportError(String)
  SendFailed(String)
}

pub type IncomingData {
  IncomingData(BitArray)
  ChannelClosed
  ChannelError(ChannelError)
}
