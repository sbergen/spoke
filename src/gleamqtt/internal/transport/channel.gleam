import gleam/erlang/process.{type Selector}
import gleam/result
import gleamqtt/internal/packet/decode.{type DecodeError}
import gleamqtt/internal/packet/encode.{type EncodeError}
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/transport.{type ChannelError}

pub type SendResult {
  SendOk
  ChannelFailed(ChannelError)
  EncodingFailed(EncodeError)
}

/// Abstraction for an encoded transport channel
pub type EncodedChannel {
  EncodedChannel(
    send: fn(outgoing.Packet) -> SendResult,
    receive: Selector(Result(incoming.Packet, DecodeError)),
  )
}

pub fn as_encoded(channel: transport.Channel) -> EncodedChannel {
  EncodedChannel(
    send(channel, _),
    receive: process.map_selector(channel.receive, decode),
  )
}

fn send(channel: transport.Channel, packet: outgoing.Packet) -> SendResult {
  case outgoing.encode_packet(packet) {
    Ok(bytes) ->
      case channel.send(bytes) {
        Error(e) -> ChannelFailed(e)
        _ -> SendOk
      }
    Error(e) -> EncodingFailed(e)
  }
}

// TODO: leftovers?
fn decode(data: transport.IncomingData) -> Result(incoming.Packet, DecodeError) {
  let assert transport.IncomingData(bytes) = data
  case incoming.decode_packet(bytes) {
    Ok(#(packet, _rest)) -> Ok(packet)
    Error(e) -> Error(e)
  }
}
