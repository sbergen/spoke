//// These tests that a client <-> server encode/decode
//// produces the original result.
//// I trust qcheck with roundtrip tests
//// as much as I would trust manually written tests.
//// This is sort of like double-entry bookkeeping.

import generators
import gleam/bytes_tree
import qcheck
import spoke/internal/packet/client/outgoing
import spoke/internal/packet/server/incoming as server_in

pub fn connect_roundtrip_test() {
  use expected_data <- qcheck.given(generators.connect_data())

  let assert Ok(bytes) = outgoing.encode_packet(outgoing.Connect(expected_data))
  let assert Ok(#(server_in.Connect(received_data), <<>>)) =
    server_in.decode_packet(bytes_tree.to_bit_array(bytes))

  received_data == expected_data
}
