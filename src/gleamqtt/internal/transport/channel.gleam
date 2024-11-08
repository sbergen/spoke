import gleam/erlang/process.{type Selector}
import gleamqtt/internal/packet/decode.{type DecodeError}
import gleamqtt/internal/packet/encode.{type EncodeError}
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/transport.{type ChannelError}

pub type SendError {
  ChannelFailed(ChannelError)
  EncodingFailed(EncodeError)
}

pub type ReceiveResult =
  Result(List(incoming.Packet), decode.DecodeError)

/// Abstraction for an encoded transport channel
pub type EncodedChannel {
  EncodedChannel(
    send: fn(outgoing.Packet) -> Result(Nil, SendError),
    receive: Selector(ReceiveResult),
  )
}

pub fn as_encoded(channel: transport.Channel) -> EncodedChannel {
  EncodedChannel(
    send(channel, _),
    receive: process.map_selector(channel.receive, decode),
  )
}

fn send(
  channel: transport.Channel,
  packet: outgoing.Packet,
) -> Result(Nil, SendError) {
  case outgoing.encode_packet(packet) {
    Ok(bytes) ->
      case channel.send(bytes) {
        Error(e) -> Error(ChannelFailed(e))
        Ok(_) -> Ok(Nil)
      }
    Error(e) -> Error(EncodingFailed(e))
  }
}

// TODO: leftovers?
fn decode(data: Result(BitArray, ChannelError)) -> ReceiveResult {
  let assert Ok(bits) = data
  case incoming.decode_packet(bits) {
    Ok(#(packet, _rest)) -> Ok([packet])
    Error(e) -> Error(e)
  }
}
