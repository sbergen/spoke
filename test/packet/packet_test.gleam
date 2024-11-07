import gleam/bit_array
import gleam/bytes_builder
import gleamqtt
import gleeunit/should
import packet
import packet/decode

pub fn encode_connect_test() {
  let assert Ok(builder) =
    packet.encode_packet(packet.Connect("test-client-id", 15))

  let assert <<1:4, 0:4, rest:bits>> = bytes_builder.to_bit_array(builder)
  let rest = validate_remaining_len(rest)
  let assert Ok(#("MQTT", rest)) = decode.string(rest)

  // Protocol level
  let assert <<4:8, rest:bits>> = rest

  // Connect flags, we always just set clean session for now
  let assert <<0b10:8, rest:bits>> = rest

  // Keep-alive
  let assert <<15:big-size(16), rest:bits>> = rest

  let assert Ok(#("test-client-id", <<>>)) = decode.string(rest)
}

pub fn encode_subscribe_test() {
  let assert Ok(builder) =
    packet.encode_packet(
      packet.Subscribe(42, [
        gleamqtt.SubscribeTopic("topic0", gleamqtt.QoS0),
        gleamqtt.SubscribeTopic("topic1", gleamqtt.QoS1),
        gleamqtt.SubscribeTopic("topic2", gleamqtt.QoS2),
      ]),
    )

  // flags are reserved
  let assert <<8:4, 2:4, rest:bits>> = bytes_builder.to_bit_array(builder)
  let rest = validate_remaining_len(rest)

  let assert <<42:big-size(16), rest:bits>> = rest

  let assert Ok(#("topic0", rest)) = decode.string(rest)
  let assert <<0:8, rest:bits>> = rest

  let assert Ok(#("topic1", rest)) = decode.string(rest)
  let assert <<1:8, rest:bits>> = rest

  let assert Ok(#("topic2", rest)) = decode.string(rest)
  let assert <<2:8>> = rest
}

pub fn encode_disconnect_test() {
  let assert Ok(builder) = packet.encode_packet(packet.Disconnect)
  let assert <<14:4, 0:4, 0:8>> = bytes_builder.to_bit_array(builder)
}

pub fn encode_ping_req_test() {
  let assert Ok(builder) = packet.encode_packet(packet.PintReq)
  let assert <<12:4, 0:4, 0:8>> = bytes_builder.to_bit_array(builder)
}

pub fn decode_too_short_test() {
  packet.decode_packet(<<0:7>>)
  |> should.equal(Error(packet.DataTooShort))
}

pub fn decode_invalid_id_test() {
  packet.decode_packet(<<0:8>>)
  |> should.equal(Error(packet.InvalidPacketIdentifier))
}

pub fn connack_decode_invalid_length_test() {
  packet.decode_packet(<<2:4, 0:4, 3:8, 0:32>>)
  |> should.equal(Error(packet.InvalidConnAckData))
}

pub fn connack_decode_invalid_flags_test() {
  packet.decode_packet(<<2:4, 1:4, 2:8, 0:16>>)
  |> should.equal(Error(packet.InvalidConnAckData))
}

pub fn connack_decode_invalid_return_code_test() {
  packet.decode_packet(<<2:4, 0:4, 2:8, 0:8, 6:8>>)
  |> should.equal(Error(packet.InvalidConnAckReturnCode))
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
  let assert Error(packet.InvalidPingRespData) =
    packet.decode_packet(<<13:4, 0:4, 1:8, 1:8>>)
}

fn validate_remaining_len(bytes: BitArray) -> BitArray {
  let assert Ok(#(remaining_len, rest)) = decode.varint(bytes)
  let actual_len = bit_array.byte_size(rest)
  remaining_len |> should.equal(actual_len)

  rest
}
