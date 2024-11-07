import gleeunit/should
import packet
import packet/decode

pub fn decode_string_invalid_length_test() {
  let assert Error(packet.InvalidStringLength) = decode.string(<<8:16, 0>>)
}

pub fn decode_string_invalid_data_test() {
  let assert Error(packet.InvalidUTF8) = decode.string(<<2:16, 0xc3, 0x28>>)
}

pub fn decode_varint_small_test() {
  decode.varint(<<0:8>>) |> should.equal(Ok(#(0, <<>>)))
  decode.varint(<<127:8, 1:8>>) |> should.equal(Ok(#(127, <<1:8>>)))
}

pub fn decode_varint_large_test() {
  // This is the example in the MQTT docs
  decode.varint(<<193:8, 2:8, 1:8>>) |> should.equal(Ok(#(321, <<1:8>>)))

  // And this is the max value in the docs
  decode.varint(<<0xFF, 0xFF, 0xFF, 0x7F>>)
  |> should.equal(Ok(#(268_435_455, <<>>)))
}

pub fn decode_varint_too_short_data_test() {
  decode.varint(<<1:1, 0:7>>) |> should.equal(Error(packet.InvalidVarint))
}

pub fn decode_varint_too_large_test() {
  decode.varint(<<0xFF, 0xFF, 0xFF, 0xFF, 1>>)
  |> should.equal(Error(packet.InvalidVarint))
}
