import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}

/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic).
pub type ByteChannel {
  ByteChannel(
    /// Function that sends the data to the channel.
    send: fn(BytesTree) -> ChannelResult(Nil),
    /// Returns a selector that publishes the next chunk of received data
    selecting_next: fn() -> Selector(ChannelResult(BitArray)),
    /// Function that shuts down the connection.
    shutdown: fn() -> Nil,
  )
}

pub type ChannelResult(a) =
  Result(a, ChannelError)

/// Generic error type for channels.
/// Will need to refine the errors later...
pub type ChannelError {
  /// The channel went from established to closed.
  ChannelClosed

  /// Connecting the channel failed.
  ConnectFailed(String)

  /// The The channel was established,
  /// but ran into an error while sending or receiving data.
  TransportError(String)

  /// We received data that was not in the expected format.
  InvalidData(String)
}
