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
  Result(List(incoming.Packet), EncodedChannelError)

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
      let #(result, rest) = decode_all(all_data)
      case result {
        Ok([]) -> Nil
        result -> process.send(state.receiver, result)
      }
      actor.continue(ChunkerState(..state, leftover: rest))
    }
  }
}

fn decode_all(data: BitArray) -> #(EncodedReceiveResult, BitArray) {
  case incoming.decode_packet(data) {
    Ok(#(packet, rest)) -> #(Ok([packet]), rest)

    Error(decode.DataTooShort) -> #(Ok([]), data)

    Error(e) -> {
      case bit_array.byte_size(data) < incoming.largest_fixed_size_packet {
        True -> #(Ok([]), data)
        False -> #(Error(ChannelDecodeError(e)), <<>>)
      }
    }
  }
}
