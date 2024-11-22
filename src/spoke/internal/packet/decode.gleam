//// Decoding of fundamental MQTT data types and shared error codes

import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleam/result.{try}
import spoke/internal/packet.{
  type ConnAckResult, type PublishData, type QoS, type SubscribeResult, QoS0,
  QoS1, QoS2,
}

pub type DecodeError {
  DecodeNotImplemented
  InvalidPacketIdentifier(Int)
  DataTooShort
  InvalidData
  InvalidUTF8
  InvalidQoS
  VarIntTooLarge
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
      let data =
        packet.PublishData(topic, rest, dup == 1, qos, retain == 1, None)
      Ok(#(construct(data), remainder))
    }
    _ -> Error(InvalidData)
  }
}

pub fn pingresp(
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
    8 -> Ok(Error(Nil))
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
