import gleam/bit_array
import gleam/erlang/process
import gleam/otp/actor
import gleam/string
import spoke/internal/packet/decode
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/transport.{type ChannelResult, type Receiver}

pub type EncodedChannel =
  transport.Channel(outgoing.Packet, incoming.Packet)

pub fn as_encoded(channel: transport.ByteChannel) -> EncodedChannel {
  let assert Ok(chunker) = actor.start(NotReceiving(channel), run_chunker)

  transport.Channel(
    send: send(channel, _),
    start_receive: fn(receiver) {
      process.send(chunker, StartReceive(receiver))
    },
    shutdown: fn() { process.send(chunker, ShutDown) },
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

type ChunkerState {
  NotReceiving(channel: transport.ByteChannel)
  Receiving(
    channel: transport.ByteChannel,
    receiver: Receiver(incoming.Packet),
    leftover: BitArray,
  )
}

type ChunkerMsg {
  StartReceive(transport.Receiver(incoming.Packet))
  IncomingData(ChannelResult(BitArray))
  ShutDown
}

fn run_chunker(
  msg: ChunkerMsg,
  state: ChunkerState,
) -> actor.Next(ChunkerMsg, ChunkerState) {
  case msg {
    IncomingData(data) -> chunk_data(data, state)
    ShutDown -> {
      let channel = case state {
        NotReceiving(channel) -> channel
        Receiving(channel, _, _) -> channel
      }
      channel.shutdown()
      actor.Stop(process.Normal)
    }
    StartReceive(receiver) -> {
      let assert NotReceiving(channel) = state
      let incoming = process.new_subject()
      channel.start_receive(incoming)

      let selector =
        process.new_selector()
        |> process.selecting(incoming, IncomingData)

      actor.with_selector(
        actor.continue(Receiving(channel, receiver, <<>>)),
        selector,
      )
    }
  }
}

fn chunk_data(
  data: ChannelResult(BitArray),
  state: ChunkerState,
) -> actor.Next(ChunkerMsg, ChunkerState) {
  let assert Receiving(channel, receiver, leftover) = state

  case data {
    Error(e) -> {
      actor.Stop(process.Abnormal(string.inspect(e)))
    }

    Ok(data) -> {
      let all_data = bit_array.concat([leftover, data])
      case decode_all(receiver, all_data) {
        Ok(rest) -> actor.continue(Receiving(channel, receiver, leftover: rest))
        Error(e) -> {
          process.send(receiver, Error(e))
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
