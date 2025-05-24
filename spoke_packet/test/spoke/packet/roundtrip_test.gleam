//// These tests that a client <-> server encode/decode
//// produces the original result.
//// I trust qcheck with roundtrip tests
//// as much as I would trust manually written tests.
//// This is sort of like double-entry bookkeeping.

import gleam/bytes_tree
import gleeunit/should
import qcheck
import spoke/packet/client/incoming
import spoke/packet/client/outgoing
import spoke/packet/generators
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub fn connect_roundtrip_test() {
  use expected_data <- qcheck.given(generators.connect_data())

  roundtrip_out(outgoing.Connect(expected_data))
  |> should.equal(server_in.Connect(expected_data))
}

pub fn connack_roundtrip_test() {
  use expected_result <- qcheck.given(generators.connack_result())

  roundtrip_in(server_out.ConnAck(expected_result))
  |> should.equal(incoming.ConnAck(expected_result))
}

pub fn subscribe_roundtrip_test() {
  use #(id, request, requests) <- qcheck.given(generators.subscribe_request())

  roundtrip_out(outgoing.Subscribe(id, request, requests))
  |> should.equal(server_in.Subscribe(id, [request, ..requests]))
}

pub fn suback_roundtrip_test() {
  use #(id, result, results) <- qcheck.given(generators.suback())

  roundtrip_in(server_out.SubAck(id, result, results))
  |> should.equal(incoming.SubAck(id, [result, ..results]))
}

pub fn unsubscribe_roundtrip_test() {
  use #(id, request, requests) <- qcheck.given(generators.unsubscribe_request())

  roundtrip_out(outgoing.Unsubscribe(id, request, requests))
  |> should.equal(server_in.Unsubscribe(id, [request, ..requests]))
}

pub fn publish_out_roundtrip_test() {
  use data <- qcheck.given(generators.valid_publish_data())

  roundtrip_out(outgoing.Publish(data))
  |> should.equal(server_in.Publish(data))
}

pub fn publish_in_roundtrip_test() {
  use data <- qcheck.given(generators.valid_publish_data())

  roundtrip_in(server_out.Publish(data))
  |> should.equal(incoming.Publish(data))
}

pub fn disconnect_roundtrip_test() {
  let assert server_in.Disconnect = roundtrip_out(outgoing.Disconnect)
}

pub fn pingreq_roundtrip_test() {
  let assert server_in.PingReq = roundtrip_out(outgoing.PingReq)
}

pub fn pingresp_roundtrip_test() {
  let assert incoming.PingResp = roundtrip_in(server_out.PingResp)
}

pub fn unsuback_roundtrip_test() {
  use id <- qcheck.given(generators.packet_id())

  roundtrip_in(server_out.UnsubAck(id))
  |> should.equal(incoming.UnsubAck(id))
}

pub fn puback_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_out(outgoing.PubAck(packet_id))
  |> should.equal(server_in.PubAck(packet_id))
}

pub fn pubrec_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_out(outgoing.PubRec(packet_id))
  |> should.equal(server_in.PubRec(packet_id))
}

pub fn pubrel_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_out(outgoing.PubRel(packet_id))
  |> should.equal(server_in.PubRel(packet_id))
}

pub fn pubcomp_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_out(outgoing.PubComp(packet_id))
  |> should.equal(server_in.PubComp(packet_id))
}

pub fn puback_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_in(server_out.PubAck(packet_id))
  |> should.equal(incoming.PubAck(packet_id))
}

pub fn pubrec_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_in(server_out.PubRec(packet_id))
  |> should.equal(incoming.PubRec(packet_id))
}

pub fn pubrel_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_in(server_out.PubRel(packet_id))
  |> should.equal(incoming.PubRel(packet_id))
}

pub fn pubcomp_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())

  roundtrip_in(server_out.PubComp(packet_id))
  |> should.equal(incoming.PubComp(packet_id))
}

/// Encodes outgoing packet, and decodes it as incoming server packet
fn roundtrip_out(out: outgoing.Packet) -> server_in.Packet {
  let bytes = outgoing.encode_packet(out)
  let assert Ok(#(packet, <<>>)) =
    server_in.decode_packet(bytes_tree.to_bit_array(bytes))
  packet
}

/// Encodes server outgoing packet, and decodes it as incoming packet
fn roundtrip_in(out: server_out.Packet) -> incoming.Packet {
  let bytes = server_out.encode_packet(out)
  let assert Ok(#(packet, <<>>)) =
    incoming.decode_packet(bytes_tree.to_bit_array(bytes))
  packet
}
