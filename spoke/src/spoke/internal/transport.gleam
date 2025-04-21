import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}

/// Abstraction over the transport channel
/// (E.g. TCP, WebSocket, Quic).
pub type ByteChannel {
  ByteChannel(
    /// Function that sends the data to the channel.
    send: fn(BytesTree) -> Result(Nil, String),
    /// Returns a selector that publishes the next chunk of received data
    selecting_next: fn() -> Selector(Result(BitArray, String)),
    /// Function that shuts down the connection.
    shutdown: fn() -> Nil,
  )
}
