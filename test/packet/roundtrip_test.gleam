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

pub fn subscribe_roundtrip_test() {
  use #(id, requests) <- qcheck.given(generators.subscribe_request())

  let assert server_in.Subscribe(rcv_id, rcv_requests) =
    roundtrip_out(outgoing.Subscribe(id, requests))

  id == rcv_id && requests == rcv_requests
}

pub fn connack_roundtrip_test() {
  use expected_result <- qcheck.given(generators.connack_result())

  let assert Ok(bytes) =
    server_out.encode_packet(server_out.ConnAck(expected_result))
  let assert Ok(#(incoming.ConnAck(received_result), <<>>)) =
    incoming.decode_packet(bytes_tree.to_bit_array(bytes))

  received_result == expected_result
}

fn roundtrip_out(out: outgoing.Packet) -> server_in.Packet {
  let assert Ok(bytes) = outgoing.encode_packet(out)
  let assert Ok(#(packet, <<>>)) =
    server_in.decode_packet(bytes_tree.to_bit_array(bytes))
  packet
}
