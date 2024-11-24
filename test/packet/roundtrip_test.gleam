//// These tests that a client <-> server encode/decode
//// produces the original result.
//// I trust qcheck with roundtrip tests
//// as much as I would trust manually written tests.
//// This is sort of like double-entry bookkeeping.

import generators
import gleam/bytes_tree
import qcheck
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn connect_roundtrip_test() {
  use expected_data <- qcheck.given(generators.connect_data())
  let assert server_in.Connect(received_data) =
    roundtrip_out(outgoing.Connect(expected_data))

  received_data == expected_data
}

pub fn connack_roundtrip_test() {
  use expected_result <- qcheck.given(generators.connack_result())
  let assert incoming.ConnAck(received_result) =
    roundtrip_in(server_out.ConnAck(expected_result))

  received_result == expected_result
}

pub fn subscribe_roundtrip_test() {
  use #(id, requests) <- qcheck.given(generators.subscribe_request())
  let assert server_in.Subscribe(rcv_id, rcv_requests) =
    roundtrip_out(outgoing.Subscribe(id, requests))

  rcv_id == id && rcv_requests == requests
}

pub fn suback_roundtrip_test() {
  use #(id, results) <- qcheck.given(generators.suback())
  let assert incoming.SubAck(rcv_id, rcv_results) =
    roundtrip_in(server_out.SubAck(id, results))

  rcv_id == id && rcv_results == results
}

pub fn unsubscribe_roundtrip_test() {
  use #(id, requests) <- qcheck.given(generators.unsubscribe_request())
  let assert server_in.Unsubscribe(rcv_id, rcv_requests) =
    roundtrip_out(outgoing.Unsubscribe(id, requests))

  id == rcv_id && requests == rcv_requests
}

pub fn publish_out_roundtrip_test() {
  use data <- qcheck.given(generators.valid_publish_data())
  let assert server_in.Publish(rcv_data) = roundtrip_out(outgoing.Publish(data))
  rcv_data == data
}

pub fn publish_in_roundtrip_test() {
  use data <- qcheck.given(generators.valid_publish_data())
  let assert incoming.Publish(rcv_data) = roundtrip_in(server_out.Publish(data))
  rcv_data == data
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
  let assert incoming.UnsubAck(rcv_id) = roundtrip_in(server_out.UnsubAck(id))
  rcv_id == id
}

pub fn puback_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert server_in.PubAck(received_id) =
    roundtrip_out(outgoing.PubAck(packet_id))
  received_id == packet_id
}

pub fn pubrec_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert server_in.PubRec(received_id) =
    roundtrip_out(outgoing.PubRec(packet_id))
  received_id == packet_id
}

pub fn pubrel_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert server_in.PubRel(received_id) =
    roundtrip_out(outgoing.PubRel(packet_id))
  received_id == packet_id
}

pub fn pubcomp_out_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert server_in.PubComp(received_id) =
    roundtrip_out(outgoing.PubComp(packet_id))
  received_id == packet_id
}

pub fn puback_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert incoming.PubAck(received_id) =
    roundtrip_in(server_out.PubAck(packet_id))
  received_id == packet_id
}

pub fn pubrec_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert incoming.PubRec(received_id) =
    roundtrip_in(server_out.PubRec(packet_id))
  received_id == packet_id
}

pub fn pubrel_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert incoming.PubRel(received_id) =
    roundtrip_in(server_out.PubRel(packet_id))
  received_id == packet_id
}

pub fn pubcomp_in_roundtrip_test() {
  use packet_id <- qcheck.given(generators.packet_id())
  let assert incoming.PubComp(received_id) =
    roundtrip_in(server_out.PubComp(packet_id))
  received_id == packet_id
}

/// Encodes outgoing packet, and decodes it as incoming server packet
fn roundtrip_out(out: outgoing.Packet) -> server_in.Packet {
  let assert Ok(bytes) = outgoing.encode_packet(out)
  let assert Ok(#(packet, <<>>)) =
    server_in.decode_packet(bytes_tree.to_bit_array(bytes))
  packet
}

/// Encodes server outgoing packet, and decodes it as incoming packet
fn roundtrip_in(out: server_out.Packet) -> incoming.Packet {
  let assert Ok(bytes) = server_out.encode_packet(out)
  let assert Ok(#(packet, <<>>)) =
    incoming.decode_packet(bytes_tree.to_bit_array(bytes))
  packet
}
