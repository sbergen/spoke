import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleam/result
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/internal/transport/channel.{type EncodedChannel}
import gleamqtt/transport
import gleeunit/should
import transport/fake_channel

pub fn send_contained_packet_test() {
  let #(raw_send, _, channel) = set_up(fake_channel.success)
  let assert Ok(_) = channel.send(outgoing.PingReq)
  process.receive(raw_send, 10) |> should.equal(Ok(encode(outgoing.PingReq)))
}

pub fn receive_contained_packet_test() {
  let #(_, raw_receive, channel) = set_up(fake_channel.success)
  process.send(raw_receive, <<13:4, 0:4, 0:8>>)
  let assert Ok(Ok([incoming.PingResp])) = process.select(channel.receive, 10)
}

fn encode(packet: outgoing.Packet) -> BitArray {
  let assert Ok(bits) =
    outgoing.encode_packet(packet)
    |> result.map(bytes_builder.to_bit_array)
  bits
}

fn set_up(
  create: fn(Subject(BitArray), Subject(BitArray)) -> transport.Channel,
) -> #(Subject(BitArray), Subject(BitArray), EncodedChannel) {
  let send = process.new_subject()
  let receive = process.new_subject()
  let channel = create(send, receive)
  let channel = channel.as_encoded(channel)
  #(send, receive, channel)
}
