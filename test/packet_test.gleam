import decode
import gleam/bit_array
import gleam/bytes_builder
import gleeunit/should
import packet

pub fn connect_test() {
  let p = packet.connect("test-client-id") |> bytes_builder.to_bit_array()

  let assert <<0b00010000, rest:bits>> = p

  // assumes len < 128 for now...
  let assert <<remaining_len:8, rest:bits>> = rest
  let actual_len = bit_array.byte_size(rest)
  remaining_len |> should.equal(actual_len)

  let assert #("MQTT", rest) = decode.string(rest)

  // Protocol level
  let assert <<4:8, rest:bits>> = rest

  // Connect flags, we always just set clean session for now
  let assert <<0b10:8, rest:bits>> = rest

  // Keep alive is hard-coded to one minute for now
  let assert <<60:big-size(16), rest:bits>> = rest

  let assert #("test-client-id", <<>>) = decode.string(rest)
}
