import gleam/erlang/process.{type Subject}
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
  Result(List(incoming.Packet), DecodeError)

/// Abstraction for an encoded transport channel
/// Note: only one receiver is supported at the moment
pub type EncodedChannel {
  EncodedChannel(
    send: fn(outgoing.Packet) -> Result(Nil, SendError),
    start_receive: fn(Subject(ReceiveResult)) -> Nil,
  )
}

pub fn as_encoded(channel: transport.Channel) -> EncodedChannel {
  EncodedChannel(send(channel, _), start_receive: fn(_) { todo }//process.map_selector(channel.receive, decode),
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
