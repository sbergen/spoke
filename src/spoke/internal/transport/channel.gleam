import gleam/bit_array
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/string
import spoke/internal/packet/decode
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/internal/transport.{type ChannelResult}

/// One-to-many mapping on the receiving side
pub type EncodedChannel =
  transport.Channel(BitArray, outgoing.Packet, List(incoming.Packet))

pub fn as_encoded(channel: transport.ByteChannel) -> EncodedChannel {
  transport.Channel(
    send: send(channel, _),
    selecting_next: selecting_next(_, channel),
    shutdown: channel.shutdown,
  )
}

fn send(
  channel: transport.ByteChannel,
  packet: outgoing.Packet,
) -> ChannelResult(Nil) {
  case outgoing.encode_packet(packet) {
    Ok(bytes) -> channel.send(bytes)
    Error(e) -> Error(transport.SendFailed(string.inspect(e)))
  }
}

fn selecting_next(
  state: BitArray,
  channel: transport.ByteChannel,
) -> Selector(#(BitArray, ChannelResult(List(incoming.Packet)))) {
  use input <- process.map_selector(channel.selecting_next(Nil))
  case input {
    #(Nil, Ok(data)) ->
      case decode(bit_array.append(state, data), []) {
        Ok(#(rest, result)) -> #(rest, Ok(list.reverse(result)))
        Error(e) -> #(<<>>, Error(transport.InvalidData(string.inspect(e))))
      }
    #(Nil, Error(e)) -> #(state, Error(e))
  }
}

fn decode(
  data: BitArray,
  packets: List(incoming.Packet),
) -> ChannelResult(#(BitArray, List(incoming.Packet))) {
  case incoming.decode_packet(data) {
    Error(decode.DataTooShort) -> Ok(#(data, packets))
    Error(e) -> Error(transport.InvalidData(string.inspect(e)))
    Ok(#(packet, rest)) -> decode(rest, [packet, ..packets])
  }
}
