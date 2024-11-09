import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/string
import gleamqtt/internal/packet/decode.{type DecodeError}
import gleamqtt/internal/packet/encode.{type EncodeError}
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/transport.{type ChannelError}

pub type SendError {
  ChannelFailed(ChannelError)
  EncodingFailed(EncodeError)
}

pub type EncodedChannelError {
  EncodedChannelError(ChannelError)
  ChannelDecodeError(DecodeError)
}

pub type EncodedReceiveResult =
  Result(incoming.Packet, EncodedChannelError)

/// Abstraction for an encoded transport channel
/// Note: only one receiver is supported at the moment
pub type EncodedChannel {
  EncodedChannel(
    send: fn(outgoing.Packet) -> Result(Nil, SendError),
    start_receive: fn(Subject(EncodedReceiveResult)) -> Nil,
  )
}

pub fn as_encoded(channel: transport.Channel) -> EncodedChannel {
  EncodedChannel(send(channel, _), fn(receiver) {
    let assert Ok(chunker) =
      actor.start(ChunkerState(receiver, <<>>), run_chunker)
    channel.start_receive(chunker)
  })
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

type ChunkerState {
  ChunkerState(receiver: Subject(EncodedReceiveResult), leftover: BitArray)
}

fn run_chunker(
  data: Result(BitArray, ChannelError),
  state: ChunkerState,
) -> actor.Next(Result(BitArray, ChannelError), ChunkerState) {
  case data {
    Error(e) -> {
      actor.Stop(process.Abnormal(string.inspect(e)))
    }

    Ok(data) -> {
      let all_data = bit_array.concat([state.leftover, data])
      case decode_all(state.receiver, all_data) {
        Ok(rest) -> actor.continue(ChunkerState(..state, leftover: rest))
        Error(e) -> {
          process.send(state.receiver, Error(e))
          actor.Stop(process.Abnormal(string.inspect(e)))
        }
      }
    }
  }
}

fn decode_all(
  receiver: Subject(EncodedReceiveResult),
  data: BitArray,
) -> Result(BitArray, EncodedChannelError) {
  case incoming.decode_packet(data) {
    Error(decode.DataTooShort) -> Ok(data)
    Error(e) -> Error(ChannelDecodeError(e))
    Ok(#(packet, rest)) -> {
      process.send(receiver, Ok(packet))
      decode_all(receiver, rest)
    }
  }
}
