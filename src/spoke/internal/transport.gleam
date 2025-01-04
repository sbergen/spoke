import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}

/// General abstraction over a data channel
/// Used internally for e.g. chunking and encoding/decoding
pub type Channel(state, send, receive) {
  Channel(
    /// Function that sends the data to the channel.
    send: fn(send) -> ChannelResult(Nil),
    /// Returns a selector that publishes the next chunk of received data
    /// together with a new state for the channel,
    /// which must be used in the next call to `selecting_next`.
    selecting_next: fn(state) -> Selector(#(state, ChannelResult(receive))),
    /// Function that shuts down the connection.
    shutdown: fn() -> Nil,
  )
}

/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic)
/// Currently we don't support state, could be added later.
pub type ByteChannel =
  Channel(Nil, BytesTree, BitArray)

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
