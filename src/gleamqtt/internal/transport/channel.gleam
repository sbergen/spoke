import gleam/bit_array
import gleam/erlang/process
import gleam/otp/actor
import gleam/string
import gleamqtt/internal/packet/decode
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/transport.{type ChannelResult, type Receiver}

pub type EncodedChannel =
  transport.Channel(outgoing.Packet, incoming.Packet)

pub fn as_encoded(channel: transport.ByteChannel) -> EncodedChannel {
  transport.Channel(send: send(channel, _), start_receive: fn(receiver) {
    let assert Ok(chunker) =
      actor.start(ChunkerState(receiver, <<>>), run_chunker)
    channel.start_receive(chunker)
  })
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

type ChunkerState {
  ChunkerState(receiver: Receiver(incoming.Packet), leftover: BitArray)
}

fn run_chunker(
  data: ChannelResult(BitArray),
  state: ChunkerState,
) -> actor.Next(ChannelResult(BitArray), ChunkerState) {
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
  receiver: Receiver(incoming.Packet),
  data: BitArray,
) -> ChannelResult(BitArray) {
  case incoming.decode_packet(data) {
    Error(decode.DataTooShort) -> Ok(data)
    Error(e) -> Error(transport.InvalidData(string.inspect(e)))
    Ok(#(packet, rest)) -> {
      process.send(receiver, Ok(packet))
      decode_all(receiver, rest)
    }
  }
}
