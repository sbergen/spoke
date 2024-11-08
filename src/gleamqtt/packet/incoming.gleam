import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleamqtt.{type QoS, type SubscribeResult, QoS0, QoS1, QoS2}
import gleamqtt/packet/decode
import gleamqtt/packet/errors.{type DecodeError}

pub type ConnectReturnCode {
  ConnectionAccepted
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub type Packet {
  ConnAck(session_preset: Bool, code: ConnectReturnCode)
  PingResp
  Publish(
    topic: String,
    payload: BitArray,
    dup: Bool,
    qos: QoS,
    retain: Bool,
    packet_id: Option(Int),
  )
  PubAck
  PubRec
  PubRel
  PubComp
  SubAck(packet_id: Int, return_codes: List(SubscribeResult))
  UsubAck
}

pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        0 -> Error(errors.InvalidPacketIdentifier)
        2 -> decode_connack(flags, rest)
        3 -> decode_publish(flags, rest)
        9 -> decode_suback(flags, rest)
        13 -> decode_pingresp(flags, rest)
        _ -> Error(errors.DecodeNotImplemented)
      }
    _ -> Error(errors.DataTooShort)
  }
}

fn decode_connack(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case flags, data {
    <<0:4>>, <<2:8, 0:7, session_present:1, return_code:8, rest:bytes>> -> {
      use return_code <- result.try(decode_connack_code(return_code))
      let result = ConnAck(session_present == 1, return_code)
      Ok(#(result, rest))
    }
    _, _ -> Error(errors.InvalidConnAckData)
  }
}

fn decode_publish(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case flags {
    <<dup:1, qos:2, retain:1>> -> {
      use qos <- result.try(decode_qos(qos))
      use #(data, remainder) <- result.try(split_var_data(data))
      // TODO: Packet id for QoS > 0
      use #(topic, rest) <- result.try(decode.string(data))

      Ok(#(Publish(topic, rest, dup == 1, qos, retain == 1, None), remainder))
    }
    _ -> Error(errors.InvalidPublishData)
  }
}

fn decode_pingresp(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case flags, data {
    <<0:4>>, <<0:8, rest:bytes>> -> Ok(#(PingResp, rest))
    _, _ -> Error(errors.InvalidPingRespData)
  }
}

fn decode_suback(
  flags: BitArray,
  data: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case flags, data {
    <<0:4>>, _ -> {
      use #(data, remainder) <- result.try(split_var_data(data))
      use #(packet_id, rest) <- result.try(decode.integer(data))
      use return_codes <- result.try(decode_suback_returns(rest, []))
      Ok(#(SubAck(packet_id, return_codes), remainder))
    }
    _, _ -> Error(errors.InvalidSubAckData)
  }
}

/// Reads the variable size value and splits the data to that length + the rest
fn split_var_data(bytes: BitArray) -> Result(#(BitArray, BitArray), DecodeError) {
  use #(len, rest) <- result.try(decode.varint(bytes))
  case rest {
    <<data:bytes-size(len), rest:bytes>> -> Ok(#(data, rest))
    _ -> Error(errors.DataTooShort)
  }
}

fn decode_connack_code(code: Int) -> Result(ConnectReturnCode, DecodeError) {
  case code {
    0 -> Ok(ConnectionAccepted)
    1 -> Ok(UnacceptableProtocolVersion)
    2 -> Ok(IdentifierRefused)
    3 -> Ok(ServerUnavailable)
    4 -> Ok(BadUsernameOrPassword)
    5 -> Ok(NotAuthorized)
    _ -> Error(errors.InvalidConnAckReturnCode)
  }
}

fn decode_suback_returns(
  bytes: BitArray,
  codes: List(SubscribeResult),
) -> Result(List(SubscribeResult), DecodeError) {
  case bytes {
    <<>> -> Ok(list.reverse(codes))
    <<val:8, rest:bytes>> -> {
      use code <- result.try(decode_suback_return(val))
      rest |> decode_suback_returns([code, ..codes])
    }
    _ -> Error(errors.InvalidSubAckData)
  }
}

fn decode_suback_return(val: Int) -> Result(SubscribeResult, DecodeError) {
  case val {
    0 -> Ok(gleamqtt.SubscribeSuccess(QoS0))
    1 -> Ok(gleamqtt.SubscribeSuccess(QoS1))
    2 -> Ok(gleamqtt.SubscribeSuccess(QoS2))
    8 -> Ok(gleamqtt.SubscribeFailure)
    _ -> Error(errors.InvalidSubAckData)
  }
}

fn decode_qos(val: Int) -> Result(QoS, errors.DecodeError) {
  case val {
    0 -> Ok(gleamqtt.QoS0)
    1 -> Ok(gleamqtt.QoS1)
    2 -> Ok(gleamqtt.QoS2)
    _ -> Error(errors.InvalidQoS)
  }
}
