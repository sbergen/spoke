import gleam/option.{None}
import gleamqtt.{QoS0, QoS1, QoS2}
import gleamqtt/packet/encode
import gleamqtt/packet/errors
import gleamqtt/packet/incoming.{SubscribeFailure, SubscribeSuccess}
import gleeunit/should

pub fn decode_too_short_test() {
  incoming.decode_packet(<<0:7>>)
  |> should.equal(Error(errors.DataTooShort))
}

pub fn decode_invalid_id_test() {
  incoming.decode_packet(<<0:8>>)
  |> should.equal(Error(errors.InvalidPacketIdentifier))
}

pub fn connack_decode_invalid_length_test() {
  incoming.decode_packet(<<2:4, 0:4, 3:8, 0:32>>)
  |> should.equal(Error(errors.InvalidConnAckData))
}

pub fn connack_decode_invalid_flags_test() {
  incoming.decode_packet(<<2:4, 1:4, 2:8, 0:16>>)
  |> should.equal(Error(errors.InvalidConnAckData))
}

pub fn connack_decode_invalid_return_code_test() {
  incoming.decode_packet(<<2:4, 0:4, 2:8, 0:8, 6:8>>)
  |> should.equal(Error(errors.InvalidConnAckReturnCode))
}

pub fn connack_decode_test() {
  let assert Ok(#(packet, rest)) =
    incoming.decode_packet(<<2:4, 0:4, 2:8, 0:16, 1:8>>)
  rest |> should.equal(<<1:8>>)
  packet |> should.equal(incoming.ConnAck(False, incoming.ConnectionAccepted))
}

pub fn connack_session_should_be_present_test() {
  let assert Ok(#(packet, _)) =
    incoming.decode_packet(<<2:4, 0:4, 2:8, 1:8, 0:8>>)
  packet |> should.equal(incoming.ConnAck(True, incoming.ConnectionAccepted))
}

pub fn connack_return_code_should_be_id_refused_test() {
  let assert Ok(#(packet, _)) =
    incoming.decode_packet(<<2:4, 0:4, 2:8, 0:8, 2:8>>)
  packet |> should.equal(incoming.ConnAck(False, incoming.IdentifierRefused))
}

pub fn ping_resp_decode_test() {
  let assert Ok(#(packet, rest)) =
    incoming.decode_packet(<<13:4, 0:4, 0:8, 1:8>>)
  rest |> should.equal(<<1:8>>)
  packet |> should.equal(incoming.PingResp)
}

pub fn ping_resp_invalid_length_test() {
  let assert Error(errors.InvalidPingRespData) =
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
      SubscribeSuccess(QoS0),
      SubscribeSuccess(QoS1),
      SubscribeSuccess(QoS2),
      SubscribeFailure,
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

  let assert Ok(#(packet, rest)) = incoming.decode_packet(data)
  rest |> should.equal(<<42:8>>)

  packet
  |> should.equal(incoming.Publish("topic", <<"foo">>, False, QoS0, False, None))
}

pub fn publish_decode_should_be_retained_test() {
  let data = <<3:4, 1:4, encode.varint(2):bits, 0:big-size(16)>>

  let assert Ok(#(packet, <<>>)) = incoming.decode_packet(data)

  packet
  |> should.equal(incoming.Publish("", <<>>, False, QoS0, True, None))
}
