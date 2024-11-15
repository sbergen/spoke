import gleam/list
import gleam/option.{None}
import gleam/result.{try}
import spoke.{type ConnectError, type QoS, QoS0, QoS1, QoS2}
import spoke/internal/packet.{type PublishData}
import spoke/internal/packet/decode.{type DecodeError}

pub type Packet {
  ConnAck(Result(Bool, ConnectError))
  PingResp
  Publish(PublishData)
  PubAck
  PubRec
  PubRel
  PubComp
  SubAck(packet_id: Int, return_codes: List(SubscribeResult))
  UsubAck
}

pub type SubscribeResult {
  SubscribeSuccess(qos: QoS)
  SubscribeFailure
}

pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        0 -> Error(decode.InvalidPacketIdentifier)
        2 -> decode_connack(flags, rest)
        3 -> decode_publish(flags, rest)
        9 -> decode_suback(flags, rest)
        13 -> decode_pingresp(flags, rest)
        _ -> Error(decode.DecodeNotImplemented)
      }
    _ -> Error(decode.DataTooShort)
  }
}

fn decode_connack(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  use #(data, rest) <- try(split_fixed_data(data, 3))
  case flags, data {
    <<0:4>>, <<2:8, 0:7, session_present:1, return_code:8>> -> {
      use status <- try(decode_connack_code(session_present, return_code))
      let result = ConnAck(status)
      Ok(#(result, rest))
    }
    _, _ -> Error(decode.InvalidConnAckData)
  }
}

fn decode_publish(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case flags {
    <<dup:1, qos:2, retain:1>> -> {
      use qos <- try(decode_qos(qos))
      use #(data, remainder) <- try(split_var_data(data))
      // TODO: Packet id for QoS > 0
      use #(topic, rest) <- try(decode.string(data))
      let data =
        packet.PublishData(topic, rest, dup == 1, qos, retain == 1, None)
      Ok(#(Publish(data), remainder))
    }
    _ -> Error(decode.InvalidPublishData)
  }
}

fn decode_pingresp(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  use #(data, rest) <- try(split_fixed_data(data, 1))
  case flags, data {
    <<0:4>>, <<0:8>> -> Ok(#(PingResp, rest))
    _, _ -> Error(decode.InvalidPingRespData)
  }
}

fn decode_suback(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case flags, data {
    <<0:4>>, _ -> {
      use #(data, remainder) <- try(split_var_data(data))
      use #(packet_id, rest) <- try(decode.integer(data))
      use return_codes <- try(decode_suback_returns(rest, []))
      Ok(#(SubAck(packet_id, return_codes), remainder))
    }
    _, _ -> Error(decode.InvalidSubAckData)
  }
}

/// Splits a fixed amount of data off the bit array, or returns DataTooShort
fn split_fixed_data(
  bytes: BitArray,
  len: Int,
) -> Result(#(BitArray, BitArray), DecodeError) {
  case bytes {
    <<data:bytes-size(len), rest:bytes>> -> Ok(#(data, rest))
    _ -> Error(decode.DataTooShort)
  }
}

/// Reads the variable size value and splits the data to that length + the rest
fn split_var_data(bytes: BitArray) -> Result(#(BitArray, BitArray), DecodeError) {
  use #(len, rest) <- try(decode.varint(bytes))
  split_fixed_data(rest, len)
}

fn decode_connack_code(
  session_present: Int,
  code: Int,
) -> Result(Result(Bool, ConnectError), DecodeError) {
  case code {
    0 -> Ok(Ok(session_present == 1))
    1 -> Ok(Error(spoke.UnacceptableProtocolVersion))
    2 -> Ok(Error(spoke.IdentifierRefused))
    3 -> Ok(Error(spoke.ServerUnavailable))
    4 -> Ok(Error(spoke.BadUsernameOrPassword))
    5 -> Ok(Error(spoke.NotAuthorized))
    _ -> Error(decode.InvalidConnAckReturnCode)
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
    _ -> Error(decode.InvalidSubAckData)
  }
}

fn decode_suback_return(val: Int) -> Result(SubscribeResult, DecodeError) {
  case val {
    0 -> Ok(SubscribeSuccess(QoS0))
    1 -> Ok(SubscribeSuccess(QoS1))
    2 -> Ok(SubscribeSuccess(QoS2))
    8 -> Ok(SubscribeFailure)
    _ -> Error(decode.InvalidSubAckData)
  }
}

fn decode_qos(val: Int) -> Result(QoS, DecodeError) {
  case val {
    0 -> Ok(spoke.QoS0)
    1 -> Ok(spoke.QoS1)
    2 -> Ok(spoke.QoS2)
    _ -> Error(decode.InvalidQoS)
  }
}
