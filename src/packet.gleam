import gleam/bytes_builder.{type BytesBuilder}
import gleam/result
import packet/encode

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
  PintReq
  PintResp
  Publish
  PubAck
  PubRec
  PubRel
  PubComp
  Subscribe
  SubAck
  Unsubscribe
  UsubAck
  Disconnect
}

pub type EncodeError {
  EncodeNotImplemented
}

pub type DecodeError {
  DecodeNotImplemented
  InvalidPacketIdentifier
  DataTooShort
  InvalidConnAckData
  InvalidConnAckReturnCode
  InvalidUTF8
  InvalidStringLength
  InvalidVarint
}

pub fn encode_packet(packet: Packet) -> Result(BytesBuilder, EncodeError) {
  case packet {
    Connect(client_id, keep_alive) -> Ok(encode_connect(client_id, keep_alive))
    Disconnect -> Ok(encode_disconnect())
    _ -> Error(EncodeNotImplemented)
  }
}

pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        0 -> Error(InvalidPacketIdentifier)
        2 -> decode_connack(flags, rest)
        _ -> Error(DecodeNotImplemented)
      }
    _ -> Error(DataTooShort)
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

fn encode_disconnect() -> BytesBuilder {
  encode_parts(14, flags: <<0:4>>, header: <<>>, payload: bytes_builder.new())
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
    _, _ -> Error(InvalidConnAckData)
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
    _ -> Error(InvalidConnAckReturnCode)
  }
}
