//// Decoding of fundamental MQTT data types and shared error codes

import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleam/result.{try}
import spoke/internal/packet.{
  type ConnAckResult, type PublishData, type QoS, type SubscribeRequest,
  type SubscribeResult, QoS0, QoS1, QoS2, SubscribeRequest,
}

pub type DecodeError {
  InvalidPacketIdentifier(Int)
  DataTooShort
  InvalidData
  InvalidUTF8
  InvalidQoS
  VarIntTooLarge
}

pub fn connect(
  flags: BitArray,
  data: BitArray,
  construct: fn(String, Int) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  // Constant header
  use _ <- try(flags |> must_equal(<<0:4>>))
  use #(data, remainder) <- try(split_var_data(data))

  // Variable header:
  // If this were to be used in an actual server,
  // we should rather return more specific errors here.
  use #(name, rest) <- try(string(data))
  use _ <- try(name |> must_equal("MQTT"))
  use rest <- try(case rest {
    <<4:8, rest:bits>> -> Ok(rest)
    _ -> Error(InvalidData)
  })

  // TODO: Use connect flags
  use #(_connect_flags, rest) <- try(split_fixed_data(rest, 1))
  use #(keep_alive, rest) <- try(integer(rest))

  // Payload:
  // TODO, read other fields based on flags
  use #(client_id, _rest) <- try(string(rest))

  Ok(#(construct(client_id, keep_alive), remainder))
}

pub fn connack(
  flags: BitArray,
  data: BitArray,
  construct: fn(ConnAckResult) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  use #(data, rest) <- try(split_fixed_data(data, 3))
  case flags, data {
    <<0:4>>, <<2:8, 0:7, session_present:1, return_code:8>> -> {
      use status <- try(decode_connack_code(session_present, return_code))
      let result = construct(status)
      Ok(#(result, rest))
    }
    _, _ -> Error(InvalidData)
  }
}

pub fn subscribe(
  flags: BitArray,
  data: BitArray,
  construct: fn(Int, List(SubscribeRequest)) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  // Constant header
  use _ <- try(flags |> must_equal(<<2:4>>))
  use #(data, remainder) <- try(split_var_data(data))

  // Variable header:
  use #(packet_id, rest) <- try(integer(data))

  // Payload:
  use requests <- try(subscribe_requests(rest, []))

  Ok(#(construct(packet_id, requests), remainder))
}

pub fn unsubscribe(
  flags: BitArray,
  data: BitArray,
  construct: fn(Int, List(String)) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  // Constant header
  use _ <- try(flags |> must_equal(<<2:4>>))
  use #(data, remainder) <- try(split_var_data(data))

  // Variable header:
  use #(packet_id, rest) <- try(integer(data))

  // Payload:
  use topics <- try(strings(rest, []))

  Ok(#(construct(packet_id, topics), remainder))
}

pub fn publish(
  flags: BitArray,
  data: BitArray,
  construct: fn(PublishData) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  case flags {
    <<dup:1, qos:2, retain:1>> -> {
      use qos <- try(decode_qos(qos))
      use #(data, remainder) <- try(split_var_data(data))
      // TODO: Packet id for QoS > 0
      use #(topic, rest) <- try(string(data))
      let msg_data = packet.MessageData(topic, rest, qos, retain == 1)
      let data = packet.PublishData(msg_data, dup == 1, None)
      Ok(#(construct(data), remainder))
    }
    _ -> Error(InvalidData)
  }
}

/// Checks that flags and length are zero,
/// no variable header or payload
pub fn zero_length(
  flags: BitArray,
  data: BitArray,
  value: packet,
) -> Result(#(packet, BitArray), DecodeError) {
  use #(data, rest) <- try(split_fixed_data(data, 1))
  case flags, data {
    <<0:4>>, <<0:8>> -> Ok(#(value, rest))
    _, _ -> Error(InvalidData)
  }
}

pub fn suback(
  flags: BitArray,
  data: BitArray,
  construct: fn(Int, List(SubscribeResult)) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  case flags, data {
    <<0:4>>, _ -> {
      use #(data, remainder) <- try(split_var_data(data))
      use #(packet_id, rest) <- try(integer(data))
      use return_codes <- try(decode_suback_returns(rest, []))
      Ok(#(construct(packet_id, return_codes), remainder))
    }
    _, _ -> Error(InvalidData)
  }
}

/// Decodes any of PubAck, PubRec, PubRel, PubComp, UnsubAck etc... 
pub fn only_packet_id(
  flags: BitArray,
  data: BitArray,
  construct: fn(Int) -> packet,
) -> Result(#(packet, BitArray), DecodeError) {
  case flags, data {
    <<0:4>>, _ -> {
      use #(data, remainder) <- try(split_var_data(data))
      case data {
        <<packet_id:big-size(16)>> -> Ok(#(construct(packet_id), remainder))
        _ -> Error(InvalidData)
      }
    }
    _, _ -> Error(InvalidData)
  }
}

/// Decode a list of strings in a fixed-length context
pub fn strings(
  bits: BitArray,
  results: List(String),
) -> Result(List(String), DecodeError) {
  case bits {
    <<>> -> Ok(list.reverse(results))
    bits -> {
      use #(str, rest) <- try({ string(bits) |> must_be_long_enough })
      rest |> strings([str, ..results])
    }
  }
}

pub fn string(bits: BitArray) -> Result(#(String, BitArray), DecodeError) {
  case bits {
    <<len:big-size(16), bytes:bytes-size(len), rest:bits>> -> {
      use str <- try(
        bit_array.to_string(bytes)
        |> result.map_error(fn(_) { InvalidUTF8 }),
      )
      Ok(#(str, rest))
    }
    _ -> Error(DataTooShort)
  }
}

/// Standard MQTT big-endian 16-bit int
pub fn integer(bits: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  case bits {
    <<val:big-size(16), rest:bytes>> -> Ok(#(val, rest))
    _ -> Error(DataTooShort)
  }
}

pub fn varint(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  accumulate_varint(0, 1, bytes)
}

fn accumulate_varint(
  value: Int,
  multiplier: Int,
  bytes: BitArray,
) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    _ if multiplier >= 268_435_456 -> Error(VarIntTooLarge)
    <<continue:1, next:7, rest:bits>> -> {
      let value = value + multiplier * next
      case continue {
        0 -> Ok(#(value, rest))
        _ -> accumulate_varint(value, 128 * multiplier, rest)
      }
    }
    _ -> Error(DataTooShort)
  }
}

/// Splits a fixed amount of data off the bit array, or returns DataTooShort
fn split_fixed_data(
  bytes: BitArray,
  len: Int,
) -> Result(#(BitArray, BitArray), DecodeError) {
  case bytes {
    <<data:bytes-size(len), rest:bytes>> -> Ok(#(data, rest))
    _ -> Error(DataTooShort)
  }
}

/// Reads the variable size value and splits the data to that length + the rest
fn split_var_data(bytes: BitArray) -> Result(#(BitArray, BitArray), DecodeError) {
  use #(len, rest) <- try(varint(bytes))
  split_fixed_data(rest, len)
}

fn must_equal(input: a, expected: a) -> Result(Nil, DecodeError) {
  case input == expected {
    True -> Ok(Nil)
    False -> Error(InvalidData)
  }
}

fn must_be_long_enough(result: Result(a, DecodeError)) -> Result(a, DecodeError) {
  case result {
    Ok(val) -> Ok(val)
    Error(DataTooShort) -> Error(InvalidData)
    Error(e) -> Error(e)
  }
}

fn decode_connack_code(
  session_present: Int,
  code: Int,
) -> Result(ConnAckResult, DecodeError) {
  case code {
    0 -> Ok(Ok(session_present == 1))
    1 -> Ok(Error(packet.UnacceptableProtocolVersion))
    2 -> Ok(Error(packet.IdentifierRefused))
    3 -> Ok(Error(packet.ServerUnavailable))
    4 -> Ok(Error(packet.BadUsernameOrPassword))
    5 -> Ok(Error(packet.NotAuthorized))
    _ -> Error(InvalidData)
  }
}

fn decode_suback_returns(
  bytes: BitArray,
  codes: List(SubscribeResult),
) -> Result(List(SubscribeResult), DecodeError) {
  case bytes {
    <<>> -> Ok(list.reverse(codes))
    <<val:8, rest:bytes>> -> {
      use code <- try(decode_suback_return(val))
      rest |> decode_suback_returns([code, ..codes])
    }
    _ -> Error(InvalidData)
  }
}

fn decode_suback_return(val: Int) -> Result(SubscribeResult, DecodeError) {
  case val {
    0 -> Ok(Ok(QoS0))
    1 -> Ok(Ok(QoS1))
    2 -> Ok(Ok(QoS2))
    0x80 -> Ok(Error(Nil))
    _ -> Error(InvalidData)
  }
}

fn subscribe_requests(
  bytes: BitArray,
  requests: List(SubscribeRequest),
) -> Result(List(SubscribeRequest), DecodeError) {
  case bytes {
    <<>> -> Ok(list.reverse(requests))
    bytes -> {
      use #(request, rest) <- try(subscribe_request(bytes))
      rest |> subscribe_requests([request, ..requests])
    }
  }
}

fn subscribe_request(
  bytes: BitArray,
) -> Result(#(SubscribeRequest, BitArray), DecodeError) {
  use #(topic_filter, rest) <- try(string(bytes))
  case rest {
    <<qos:8, rest:bytes>> -> {
      use qos <- try(decode_qos(qos))
      Ok(#(SubscribeRequest(topic_filter, qos), rest))
    }
    // This is used only in a fixed-length context!
    _ -> Error(InvalidData)
  }
}

fn decode_qos(val: Int) -> Result(QoS, DecodeError) {
  case val {
    0 -> Ok(QoS0)
    1 -> Ok(QoS1)
    2 -> Ok(QoS2)
    _ -> Error(InvalidQoS)
  }
}
