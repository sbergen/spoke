import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleam/result
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/internal/transport/channel.{
  type EncodedChannel, type EncodedReceiveResult,
}
import gleamqtt/transport
import gleeunit/should
import transport/fake_channel

pub fn send_contained_packet_test() {
  let #(channel, send) = set_up_send()
  let assert Ok(_) = channel.send(outgoing.PingReq)
  process.receive(send, 10) |> should.equal(Ok(encode(outgoing.PingReq)))
}

pub fn receive_contained_packet_test() {
  let #(receive, raw_receive) = set_up_receive()

  process.send(raw_receive, Ok(<<13:4, 0:4, 0:8>>))
  let assert Ok(Ok(incoming.PingResp)) = process.receive(receive, 10)

  process.send(raw_receive, Ok(<<13:4, 0:4, 0:8>>))
  let assert Ok(Ok(incoming.PingResp)) = process.receive(receive, 10)
}

pub fn receive_split_packet_test() {
  let #(receive, raw_receive) = set_up_receive()

  process.send(raw_receive, Ok(<<13:4, 0:4>>))
  process.send(raw_receive, Ok(<<0:8>>))

  let assert Ok(Ok(incoming.PingResp)) = process.receive(receive, 10)
  let assert Error(Nil) = process.receive(receive, 1)
}

pub fn receive_multiple_packets_test() {
  let #(receive, raw_receive) = set_up_receive()

  let connack = <<2:4, 0:4, 2:8, 0:16>>
  let pingresp = <<13:4, 0:4, 0:8>>
  process.send(raw_receive, Ok(<<connack:bits, pingresp:bits>>))
  let assert Ok(Ok(incoming.ConnAck(_, _))) = process.receive(receive, 10)
  let assert Ok(Ok(incoming.PingResp)) = process.receive(receive, 10)
}

pub fn receive_multiple_packets_split_test() {
  let #(receive, raw_receive) = set_up_receive()

  let connack = <<2:4, 0:4, 2:8, 0:16>>
  let pingresp_start = <<13:4, 0:4>>
  let pingresp_rest = <<0:8>>
  process.send(raw_receive, Ok(<<connack:bits, pingresp_start:bits>>))
  let assert Ok(Ok(incoming.ConnAck(_, _))) = process.receive(receive, 10)

  process.send(raw_receive, Ok(pingresp_rest))
  let assert Ok(Ok(incoming.PingResp)) = process.receive(receive, 10)
}

fn encode(packet: outgoing.Packet) -> BitArray {
  let assert Ok(bits) =
    outgoing.encode_packet(packet)
    |> result.map(bytes_builder.to_bit_array)
  bits
}

fn set_up_send() -> #(EncodedChannel, Subject(BitArray)) {
  let send = process.new_subject()
  let #(channel, _) = fake_channel.new(send)
  let channel = channel.as_encoded(channel)
  #(channel, send)
}

fn set_up_receive() -> #(
  Subject(EncodedReceiveResult),
  transport.Receiver(BitArray),
) {
  let #(channel, receiver_sub) = fake_channel.new(process.new_subject())
  let channel = channel.as_encoded(channel)

  let receiver = process.new_subject()
  channel.start_receive(receiver)
  let assert Ok(raw_eceiver) = process.receive(receiver_sub, 10)

  #(receiver, raw_eceiver)
}
