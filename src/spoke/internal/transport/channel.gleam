import gleam/bit_array
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/string
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/packet/decode
import spoke/internal/transport

/// Channel with one-to-many mapping on the receiving side
/// and leftover binary data as state.
pub type EncodedChannel {
  EncodedChannel(
    /// Function that encodes and sends the packets to the channel.
    send: fn(outgoing.Packet) -> Result(Nil, String),
    /// Returns a selector that publishes the next received packets
    /// together with a new state for the channel,
    /// which must be used in the next call to `selecting_next`.
    selecting_next: fn(BitArray) ->
      Selector(#(BitArray, Result(List(incoming.Packet), String))),
    /// Function that shuts down the connection.
    shutdown: fn() -> Nil,
  )
}

pub fn as_encoded(channel: transport.ByteChannel) -> EncodedChannel {
  EncodedChannel(
    send: send(channel, _),
    selecting_next: selecting_next(_, channel),
    shutdown: channel.shutdown,
  )
}

fn send(
  channel: transport.ByteChannel,
  packet: outgoing.Packet,
) -> Result(Nil, String) {
  case outgoing.encode_packet(packet) {
    Ok(bytes) -> channel.send(bytes)
    Error(e) -> Error("Encode error: " <> string.inspect(e))
  }
}

fn selecting_next(
  state: BitArray,
  channel: transport.ByteChannel,
) -> Selector(#(BitArray, Result(List(incoming.Packet), String))) {
  use input <- process.map_selector(channel.selecting_next())
  case input {
    Ok(data) ->
      case decode(bit_array.append(state, data), []) {
        Ok(#(rest, result)) -> #(rest, Ok(list.reverse(result)))
        Error(e) -> #(<<>>, Error("Invalid data: " <> string.inspect(e)))
      }
    Error(e) -> #(state, Error(e))
  }
}

fn decode(
  data: BitArray,
  packets: List(incoming.Packet),
) -> Result(#(BitArray, List(incoming.Packet)), String) {
  case incoming.decode_packet(data) {
    Error(decode.DataTooShort) -> Ok(#(data, packets))
    Error(e) -> Error("Invalid data: " <> string.inspect(e))
    Ok(#(packet, rest)) -> decode(rest, [packet, ..packets])
  }
}
