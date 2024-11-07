import gleamqtt.{QoS0, QoS1, QoS2, SubscribeFailure, SubscribeSuccess}
import gleeunit/should
import packet
import packet/encode
import packet/errors

pub fn decode_too_short_test() {
  packet.decode_packet(<<0:7>>)
  |> should.equal(Error(errors.DataTooShort))
}

pub fn decode_invalid_id_test() {
  packet.decode_packet(<<0:8>>)
  |> should.equal(Error(errors.InvalidPacketIdentifier))
}

pub fn connack_decode_invalid_length_test() {
  packet.decode_packet(<<2:4, 0:4, 3:8, 0:32>>)
  |> should.equal(Error(errors.InvalidConnAckData))
}

pub fn connack_decode_invalid_flags_test() {
  packet.decode_packet(<<2:4, 1:4, 2:8, 0:16>>)
  |> should.equal(Error(errors.InvalidConnAckData))
}

pub fn connack_decode_invalid_return_code_test() {
  packet.decode_packet(<<2:4, 0:4, 2:8, 0:8, 6:8>>)
  |> should.equal(Error(errors.InvalidConnAckReturnCode))
}

pub fn connack_decode_test() {
  let assert Ok(#(packet, rest)) =
    packet.decode_packet(<<2:4, 0:4, 2:8, 0:16, 1:8>>)
  rest |> should.equal(<<1:8>>)
  packet |> should.equal(packet.ConnAck(False, packet.ConnectionAccepted))
}

pub fn connack_session_should_be_present_test() {
  let assert Ok(#(packet, _)) =
    packet.decode_packet(<<2:4, 0:4, 2:8, 1:8, 0:8>>)
  packet |> should.equal(packet.ConnAck(True, packet.ConnectionAccepted))
}

pub fn connack_return_code_should_be_id_refused_test() {
  let assert Ok(#(packet, _)) =
    packet.decode_packet(<<2:4, 0:4, 2:8, 0:8, 2:8>>)
  packet |> should.equal(packet.ConnAck(False, packet.IdentifierRefused))
}

pub fn ping_resp_decode_test() {
  let assert Ok(#(packet, rest)) = packet.decode_packet(<<13:4, 0:4, 0:8, 1:8>>)
  rest |> should.equal(<<1:8>>)
  packet |> should.equal(packet.PingResp)
}

pub fn ping_resp_invalid_length_test() {
  let assert Error(errors.InvalidPingRespData) =
    packet.decode_packet(<<13:4, 0:4, 1:8, 1:8>>)
}

pub fn sub_ack_decode_test() {
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

  let assert Ok(#(packet, rest)) = packet.decode_packet(data)
  rest |> should.equal(<<42:8>>)

  packet
  |> should.equal(
    packet.SubAck(packet_id: 42, return_codes: [
      SubscribeSuccess(QoS0),
      SubscribeSuccess(QoS1),
      SubscribeSuccess(QoS2),
      SubscribeFailure,
    ]),
  )
}
