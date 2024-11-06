import decode
import encode
import gleeunit/should

// These tests use the decode module,
// but that should be good enough to ensure they keep functioning correctly.

pub fn encode_string_empty_test() {
  encode.string("")
  |> decode.string
  |> should.equal("")
}

pub fn encode_string_non_empty_test() {
  let expected = "🌟 non-empty 🌟"
  encode.string(expected)
  |> decode.string
  |> should.equal(expected)
}

pub fn encode_varint_small_test() {
  encode.varint(0) |> should.equal(<<0:8>>)
  encode.varint(127) |> should.equal(<<127:8>>)
}

pub fn encode_varint_large_test() {
  // This is the example in the MQTT docs
  encode.varint(321) |> should.equal(<<193:8, 2:8>>)

  // And this is the max value in the docs
  encode.varint(268_435_455) |> should.equal(<<0xFF, 0xFF, 0xFF, 0x7F>>)
}
