import gleam/bit_array
import gleam/bytes_builder
import gleeunit/should
import packet.{ConnAck, Connect, Disconnect}
import packet/decode

pub fn encode_connect_test() {
  let assert Ok(builder) = packet.encode_packet(Connect("test-client-id"))

  let assert <<1:4, 0:4, rest:bits>> = bytes_builder.to_bit_array(builder)

  // TODO assumes len < 128 for now...
  let assert <<remaining_len:8, rest:bits>> = rest
  let actual_len = bit_array.byte_size(rest)
  remaining_len |> should.equal(actual_len)

  let assert Ok(#("MQTT", rest)) = decode.string(rest)

  // Protocol level
  let assert <<4:8, rest:bits>> = rest

  // Connect flags, we always just set clean session for now
  let assert <<0b10:8, rest:bits>> = rest

  // Keep alive is hard-coded to one minute for now
  let assert <<60:big-size(16), rest:bits>> = rest

  let assert Ok(#("test-client-id", <<>>)) = decode.string(rest)
}

pub fn encode_disconnect_test() {
  let assert Ok(builder) = packet.encode_packet(Disconnect)
  let assert <<14:4, 0:4, 0:8>> = bytes_builder.to_bit_array(builder)
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
  let assert Ok(#(packet, rest)) = packet.decode_packet(<<2:4, 0:4, 2:8, 0:16>>)
  rest |> should.equal(<<>>)
  packet |> should.equal(ConnAck(False, packet.ConnectionAccepted))
}

pub fn connack_session_should_be_present_test() {
  let assert Ok(#(packet, _)) =
    packet.decode_packet(<<2:4, 0:4, 2:8, 1:8, 0:8>>)
  packet |> should.equal(ConnAck(True, packet.ConnectionAccepted))
}

pub fn connack_return_code_should_be_id_refused_test() {
  let assert Ok(#(packet, _)) =
    packet.decode_packet(<<2:4, 0:4, 2:8, 0:8, 2:8>>)
  packet |> should.equal(ConnAck(False, packet.IdentifierRefused))
}
