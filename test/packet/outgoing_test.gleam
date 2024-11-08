import gleam/bit_array
import gleam/bytes_builder
import gleamqtt
import gleamqtt/internal/packet/decode
import gleamqtt/internal/packet/outgoing
import gleeunit/should

pub fn encode_connect_test() {
  let assert Ok(builder) =
    outgoing.encode_packet(outgoing.Connect("test-client-id", 15))

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
    outgoing.encode_packet(
      outgoing.Subscribe(42, [
        outgoing.SubscribeSpec("topic0", gleamqtt.QoS0),
        outgoing.SubscribeSpec("topic1", gleamqtt.QoS1),
        outgoing.SubscribeSpec("topic2", gleamqtt.QoS2),
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
  let assert Ok(builder) = outgoing.encode_packet(outgoing.Disconnect)
  let assert <<14:4, 0:4, 0:8>> = bytes_builder.to_bit_array(builder)
}

pub fn encode_ping_req_test() {
  let assert Ok(builder) = outgoing.encode_packet(outgoing.PingReq)
  let assert <<12:4, 0:4, 0:8>> = bytes_builder.to_bit_array(builder)
}

fn validate_remaining_len(bytes: BitArray) -> BitArray {
  let assert Ok(#(remaining_len, rest)) = decode.varint(bytes)
  let actual_len = bit_array.byte_size(rest)
  remaining_len |> should.equal(actual_len)

  rest
}
