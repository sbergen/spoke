import decode
import gleam/bit_array.{slice}
import gleam/bytes_builder
import gleeunit/should
import packet

pub fn connect_test() {
  let p = packet.connect("test-client-id") |> bytes_builder.to_bit_array()

  let assert Ok(first_byte) = slice(p, 0, 1)
  first_byte |> should.equal(<<0b00010000>>)

  // assumes len < 128 for now...
  let assert Ok(<<remaining_len>>) = slice(p, 1, 1)
  let actual_len = bit_array.byte_size(p) - 2
  remaining_len |> should.equal(actual_len)

  decode.string(remaining(p, 2)) |> should.equal("MQTT")

  // Protocol level
  slice(p, 8, 1) |> should.equal(Ok(<<4>>))

  // Connect flags, we always just set clean session for now
  slice(p, 9, 1) |> should.equal(Ok(<<0b10:8>>))

  // Keep alive is hard-coded to one minute for now
  slice(p, 10, 2) |> should.equal(Ok(<<60:big-size(16)>>))

  decode.string(remaining(p, 12)) |> should.equal("test-client-id")
}

fn remaining(bits: BitArray, start: Int) -> BitArray {
  let len = bit_array.byte_size(bits)
  let assert Ok(result) = slice(bits, start, len - start)
  result
}
