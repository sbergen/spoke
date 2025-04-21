import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/string
import spoke/internal/packet/client/incoming
import spoke/internal/packet/decode

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

// TODO: Test when I know where it will live
pub fn decode(
  data: BitArray,
) -> #(BitArray, Result(List(incoming.Packet), String)) {
  case decode_all(data, []) {
    Ok(#(rest, result)) -> #(rest, Ok(list.reverse(result)))
    Error(e) -> #(<<>>, Error("Invalid data: " <> string.inspect(e)))
  }
}

fn decode_all(
  data: BitArray,
  packets: List(incoming.Packet),
) -> Result(#(BitArray, List(incoming.Packet)), String) {
  case incoming.decode_packet(data) {
    Error(decode.DataTooShort) -> Ok(#(data, packets))
    Error(e) -> Error("Invalid data: " <> string.inspect(e))
    Ok(#(packet, rest)) -> decode_all(rest, [packet, ..packets])
  }
}
