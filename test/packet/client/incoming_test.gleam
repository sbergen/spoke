import gleam/option.{None}
import gleeunit/should
import spoke/internal/packet.{QoS0, QoS1, QoS2}
import spoke/internal/packet/client/incoming
import spoke/internal/packet/decode.{InvalidData}
import spoke/internal/packet/encode

pub fn decode_too_short_test() {
  incoming.decode_packet(<<0:7>>)
  |> should.equal(Error(decode.DataTooShort))
}

pub fn decode_invalid_id_test() {
  incoming.decode_packet(<<0:8>>)
  |> should.equal(Error(decode.InvalidPacketIdentifier(0)))
}

pub fn connack_decode_test() {
  let assert Ok(#(packet, rest)) =
    incoming.decode_packet(<<2:4, 0:4, 2:8, 0:16, 1:8>>)
  rest |> should.equal(<<1:8>>)
  packet |> should.equal(incoming.ConnAck(Ok(False)))
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

pub fn connack_session_should_be_present_test() {
  let assert Ok(#(packet, _)) =
    incoming.decode_packet(<<2:4, 0:4, 2:8, 1:8, 0:8>>)
  packet |> should.equal(incoming.ConnAck(Ok(True)))
}

pub fn connack_return_code_should_be_id_refused_test() {
  let assert Ok(#(packet, _)) =
    incoming.decode_packet(<<2:4, 0:4, 2:8, 0:8, 2:8>>)
  packet |> should.equal(incoming.ConnAck(Error(packet.IdentifierRefused)))
}

pub fn ping_resp_decode_test() {
  let assert Ok(#(packet, rest)) =
    incoming.decode_packet(<<13:4, 0:4, 0:8, 1:8>>)
  rest |> should.equal(<<1:8>>)
  packet |> should.equal(incoming.PingResp)
}

pub fn ping_resp_too_short_test() {
  let assert Error(decode.DataTooShort) = incoming.decode_packet(<<13:4, 0:4>>)
}

pub fn ping_resp_invalid_length_test() {
  let assert Error(decode.InvalidData) =
    incoming.decode_packet(<<13:4, 0:4, 1:8, 1:8>>)
}

pub fn suback_decode_test() {
  // id + 4 status codes
  let data_len = 2 + 4
  let data = <<
    9:4,
    0:4,
    encode.varint(data_len):bits,
    42:big-size(16),
    0:8,
    1:8,
    2:8,
    8:8,
    42:8,
  >>

  let assert Ok(#(packet, rest)) = incoming.decode_packet(data)
  rest |> should.equal(<<42:8>>)

  packet
  |> should.equal(
    incoming.SubAck(packet_id: 42, return_codes: [
      Ok(QoS0),
      Ok(QoS1),
      Ok(QoS2),
      Error(Nil),
    ]),
  )
}

pub fn publish_decode_qos0_test() {
  // topic length + topic + payload (raw)
  let len = 2 + 5 + 3
  let data = <<
    3:4,
    0:4,
    encode.varint(len):bits,
    5:big-size(16),
    "topic",
    "foo",
    42:8,
  >>

  let assert Ok(#(incoming.Publish(data), rest)) = incoming.decode_packet(data)
  rest |> should.equal(<<42:8>>)

  data
  |> should.equal(packet.PublishData(
    "topic",
    <<"foo">>,
    dup: False,
    qos: QoS0,
    retain: False,
    packet_id: None,
  ))
}

pub fn publish_decode_should_be_retained_test() {
  let data = <<3:4, 1:4, encode.varint(2):bits, 0:big-size(16)>>

  let assert Ok(#(incoming.Publish(data), <<>>)) = incoming.decode_packet(data)

  data
  |> should.equal(packet.PublishData(
    "",
    <<>>,
    False,
    QoS0,
    retain: True,
    packet_id: None,
  ))
}

pub fn pub_xxx_decode_test() {
  let data = <<4:4, 0:4, encode.varint(2):bits, 42:big-size(16)>>
  let assert Ok(#(incoming.PubAck(42), <<>>)) = incoming.decode_packet(data)

  let data = <<5:4, 0:4, encode.varint(2):bits, 43:big-size(16), 1>>
  let assert Ok(#(incoming.PubRec(43), <<1>>)) = incoming.decode_packet(data)

  let data = <<6:4, 0:4, encode.varint(2):bits, 44:big-size(16)>>
  let assert Ok(#(incoming.PubRel(44), <<>>)) = incoming.decode_packet(data)

  let data = <<7:4, 0:4, encode.varint(2):bits, 45:big-size(16)>>
  let assert Ok(#(incoming.PubComp(45), <<>>)) = incoming.decode_packet(data)
}

pub fn pub_xxx_decode_invalid_test() {
  // Size is too long
  let data = <<4:4, 0:4, encode.varint(3):bits, 42:big-size(16), 1>>
  let assert Error(InvalidData) = incoming.decode_packet(data)

  // flags are invalid
  let data = <<5:4, 1:4, encode.varint(2):bits, 43:big-size(16)>>
  let assert Error(InvalidData) = incoming.decode_packet(data)
}
