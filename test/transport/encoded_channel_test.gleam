import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/result
import gleeunit/should
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/transport.{type EncodedChannel}

pub fn send_contained_packet_test() {
  let #(channel, sent) = set_up_send()
  let assert Ok(_) = channel.send(outgoing.PingReq)
  process.receive(sent, 10) |> should.equal(Ok(encode(outgoing.PingReq)))
}

pub fn receive_contained_packet_test() {
  let #(channel, receive) = set_up_receive()

  process.send(receive, <<13:4, 0:4, 0:8>>)
  let assert #(<<>>, [incoming.PingResp]) = receive_next(channel, <<>>)

  process.send(receive, <<13:4, 0:4, 0:8>>)
  let assert #(<<>>, [incoming.PingResp]) = receive_next(channel, <<>>)
}

pub fn receive_split_packet_test() {
  let #(channel, receive) = set_up_receive()

  process.send(receive, <<13:4, 0:4>>)
  let assert #(state, []) = receive_next(channel, <<>>)

  process.send(receive, <<0:8>>)
  let assert #(<<>>, [incoming.PingResp]) = receive_next(channel, state)
}

pub fn receive_multiple_packets_test() {
  let #(channel, receive) = set_up_receive()

  let connack = <<2:4, 0:4, 2:8, 0:16>>
  let pingresp = <<13:4, 0:4, 0:8>>
  process.send(receive, <<connack:bits, pingresp:bits>>)

  let assert #(<<>>, [incoming.ConnAck(_), incoming.PingResp]) =
    receive_next(channel, <<>>)
}

pub fn shutdown_shuts_down_underlying_channel_test() {
  let shutdowns = process.new_subject()
  let channel =
    transport.ByteChannel(
      send: fn(_) { panic },
      selecting_next: fn() { panic },
      shutdown: fn() { process.send(shutdowns, Nil) },
    )
    |> transport.encode_channel

  channel.shutdown()
  let assert Ok(Nil) = process.receive(shutdowns, 10)
}

fn encode(packet: outgoing.Packet) -> BitArray {
  let assert Ok(bits) =
    outgoing.encode_packet(packet)
    |> result.map(bytes_tree.to_bit_array)
  bits
}

fn set_up_send() -> #(EncodedChannel, Subject(BitArray)) {
  let sent = process.new_subject()
  let raw_channel =
    transport.ByteChannel(
      send: fn(builder) {
        process.send(sent, bytes_tree.to_bit_array(builder))
        Ok(Nil)
      },
      selecting_next: fn() { panic },
      shutdown: fn() { panic },
    )

  #(transport.encode_channel(raw_channel), sent)
}

fn set_up_receive() -> #(EncodedChannel, Subject(BitArray)) {
  let receive = process.new_subject()
  let raw_channel =
    transport.ByteChannel(
      send: fn(_) { panic },
      selecting_next: fn() {
        process.new_selector()
        |> process.selecting(receive, fn(data) { Ok(data) })
      },
      shutdown: fn() { panic },
    )

  let channel = transport.encode_channel(raw_channel)
  #(channel, receive)
}

fn receive_next(
  channel: EncodedChannel,
  state: BitArray,
) -> #(BitArray, List(incoming.Packet)) {
  let assert Ok(#(state, Ok(packets))) =
    process.select(channel.selecting_next(state), 100)
  #(state, packets)
}
