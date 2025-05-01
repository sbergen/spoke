import gleeunit/should
import spoke/packet/client/incoming
import spoke/packet/decode.{InvalidData}
import spoke/packet/encode

pub fn decode_too_short_test() {
  incoming.decode_packet(<<0:7>>)
  |> should.equal(Error(decode.DataTooShort))
}

pub fn decode_invalid_id_test() {
  incoming.decode_packet(<<0:8>>)
  |> should.equal(Error(decode.InvalidPacketIdentifier(0)))
}

pub fn connack_decode_invalid_length_test() {
  incoming.decode_packet(<<2:4, 0:4, 3:8, 0:32>>)
  |> should.equal(Error(decode.InvalidData))
}

pub fn connack_decode_too_short_test() {
  incoming.decode_packet(<<2:4, 1:4, 2:8, 0:8>>)
  |> should.equal(Error(decode.DataTooShort))
}

pub fn connack_decode_invalid_flags_test() {
  incoming.decode_packet(<<2:4, 1:4, 2:8, 0:16>>)
  |> should.equal(Error(decode.InvalidData))
}

pub fn connack_decode_invalid_return_code_test() {
  incoming.decode_packet(<<2:4, 0:4, 2:8, 0:8, 6:8>>)
  |> should.equal(Error(decode.InvalidData))
}

pub fn ping_resp_too_short_test() {
  let assert Error(decode.DataTooShort) = incoming.decode_packet(<<13:4, 0:4>>)
}

pub fn ping_resp_invalid_length_test() {
  let assert Error(decode.InvalidData) =
    incoming.decode_packet(<<13:4, 0:4, 1:8, 1:8>>)
}

pub fn pub_xxx_decode_invalid_test() {
  // Size is too long
  let data = <<4:4, 0:4, encode.varint(3):bits, 42:big-size(16), 1>>
  let assert Error(InvalidData) = incoming.decode_packet(data)

  // flags are invalid
  let data = <<5:4, 1:4, encode.varint(2):bits, 43:big-size(16)>>
  let assert Error(InvalidData) = incoming.decode_packet(data)
}
