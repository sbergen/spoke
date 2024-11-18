import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}

/// General abstraction over a data channel
/// Used internally for e.g. chunking and encoding/decoding
pub type Channel(state, send, receive) {
  Channel(
    send: fn(send) -> ChannelResult(Nil),
    selecting_next: fn(state) -> Selector(#(state, ChannelResult(receive))),
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
  ChannelClosed
  ConnectFailed(String)
  TransportError(String)
  SendFailed(String)
  InvalidData(String)
}
