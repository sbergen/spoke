import gleam/bit_array
import gleeunit/should
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/internal/decode

pub fn decode_string_too_short_test() {
  let assert Error(packet.DataTooShort) = decode.string(<<8:16, 0>>)
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
  decode.varint(<<1:1, 0:7>>) |> should.equal(Error(packet.DataTooShort))
}

pub fn decode_varint_too_large_test() {
  decode.varint(<<0xFF, 0xFF, 0xFF, 0xFF, 1>>)
  |> should.equal(Error(packet.VarIntTooLarge))
}

pub fn all_contained_packets_test() {
  let assert Ok(#([incoming.PingResp], <<>>)) =
    decode.all(<<13:4, 0:4, 0:8>>, incoming.decode_packet)
}

pub fn all_split_packet_test() {
  let assert Ok(#([], leftover)) =
    decode.all(<<13:4, 0:4>>, incoming.decode_packet)

  let data = bit_array.append(leftover, <<0:8>>)
  let assert Ok(#([incoming.PingResp], <<>>)) =
    decode.all(data, incoming.decode_packet)
}

pub fn all_multiple_packets_test() {
  let connack = <<2:4, 0:4, 2:8, 0:16>>
  let pingresp = <<13:4, 0:4, 0:8>>

  let assert Ok(#([incoming.ConnAck(_), incoming.PingResp], <<>>)) =
    decode.all(<<connack:bits, pingresp:bits>>, incoming.decode_packet)
}

pub fn all_invalid_data_test() {
  let assert Error(packet.InvalidPacketIdentifier(_)) =
    decode.all(<<13:4, 0:4, 0:8, 255>>, incoming.decode_packet)
}
