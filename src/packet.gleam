import gleam/bytes_builder.{type BytesBuilder}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleamqtt.{
  type QoS, type SubAckReturnCode, type SubscribeTopic, QoS0, QoS1, QoS2,
}
import packet/decode
import packet/encode
import packet/errors.{type DecodeError, type EncodeError}

const protocol_level: Int = 4

pub type ConnectReturnCode {
  ConnectionAccepted
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub type Packet {
  Connect(client_id: String, keep_alive: Int)
  ConnAck(session_preset: Bool, code: ConnectReturnCode)
  PingReq
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
  Subscribe(packet_id: Int, topics: List(SubscribeTopic))
  SubAck(packet_id: Int, return_codes: List(SubAckReturnCode))
  Unsubscribe
  UsubAck
  Disconnect
}

pub fn encode_packet(packet: Packet) -> Result(BytesBuilder, EncodeError) {
  case packet {
    Connect(client_id, keep_alive) -> Ok(encode_connect(client_id, keep_alive))
    Disconnect -> Ok(encode_disconnect())
    Subscribe(id, topics) -> encode_subscribe(id, topics)
    PingReq -> Ok(encode_ping_req())
    _ -> Error(errors.EncodeNotImplemented)
  }
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

fn encode_connect(client_id: String, keep_alive: Int) -> BytesBuilder {
  let user_name = 0
  let password = 0
  let will_retain = 0
  let will_qos = 0
  let will_flag = 0
  let clean_session = 1

  let header = <<
    encode.string("MQTT"):bits,
    protocol_level:8,
    user_name:1,
    password:1,
    will_retain:1,
    will_qos:2,
    will_flag:1,
    clean_session:1,
    0:1,
    keep_alive:big-size(16),
  >>

  let payload =
    bytes_builder.new()
    |> bytes_builder.append(encode.string(client_id))
  // More strings to be added here

  encode_parts(1, <<0:4>>, header, payload)
}

fn encode_subscribe(
  packet_id: Int,
  topics: List(SubscribeTopic),
) -> Result(BytesBuilder, EncodeError) {
  case topics {
    [] -> Error(errors.EmptySubscribeList)
    _ -> {
      let header = <<packet_id:big-size(16)>>
      let payload = {
        use builder, topic <- list.fold(topics, bytes_builder.new())
        builder
        |> bytes_builder.append(encode.string(topic.filter))
        |> bytes_builder.append(encode_qos(topic.qos))
      }

      Ok(encode_parts(8, <<2:4>>, header, payload))
    }
  }
}

fn encode_disconnect() -> BytesBuilder {
  encode_parts(14, flags: <<0:4>>, header: <<>>, payload: bytes_builder.new())
}

fn encode_ping_req() -> BytesBuilder {
  encode_parts(12, flags: <<0:4>>, header: <<>>, payload: bytes_builder.new())
}

fn encode_parts(
  id: Int,
  flags flags: BitArray,
  header header: BitArray,
  payload payload: BytesBuilder,
) {
  let variable_content =
    payload
    |> bytes_builder.prepend(header)
  let remaining_len = bytes_builder.byte_size(variable_content)
  let fixed_header = <<id:4, flags:bits, encode.varint(remaining_len):bits>>
  bytes_builder.prepend(variable_content, fixed_header)
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
  codes: List(SubAckReturnCode),
) -> Result(List(SubAckReturnCode), DecodeError) {
  case bytes {
    <<>> -> Ok(list.reverse(codes))
    <<val:8, rest:bytes>> -> {
      use code <- result.try(decode_suback_return(val))
      rest |> decode_suback_returns([code, ..codes])
    }
    _ -> Error(errors.InvalidSubAckData)
  }
}

fn decode_suback_return(val: Int) -> Result(SubAckReturnCode, DecodeError) {
  case val {
    0 -> Ok(gleamqtt.SubscribeSuccess(QoS0))
    1 -> Ok(gleamqtt.SubscribeSuccess(QoS1))
    2 -> Ok(gleamqtt.SubscribeSuccess(QoS2))
    8 -> Ok(gleamqtt.SubscribeFailure)
    _ -> Error(errors.InvalidSubAckData)
  }
}

fn encode_qos(qos: QoS) -> BitArray {
  <<
    case qos {
      gleamqtt.QoS0 -> 0
      gleamqtt.QoS1 -> 1
      gleamqtt.QoS2 -> 2
    },
  >>
}

fn decode_qos(val: Int) -> Result(QoS, errors.DecodeError) {
  case val {
    0 -> Ok(gleamqtt.QoS0)
    1 -> Ok(gleamqtt.QoS1)
    2 -> Ok(gleamqtt.QoS2)
    _ -> Error(errors.InvalidQoS)
  }
}
