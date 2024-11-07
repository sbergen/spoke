import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}
import gleam/result
import packet/encode

const protocol_level: Int = 4

const keep_alive_seconds: Int = 60

pub type ConnectReturnCode {
  ConnectionAccepted
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub type Packet {
  Connect(client_id: String)
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
  InvalidPacketIdentifier
  DataTooShort
  InvalidConnAckData
  InvalidConnAckReturnCode
}

pub fn encode_packet(packet: Packet) -> Result(BytesBuilder, EncodeError) {
  case packet {
    Connect(client_id) -> Ok(decode_connect(client_id))
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
        _ -> panic as "Not done, but I don't wan't a warning"
      }
    _ -> Error(DataTooShort)
  }
}

fn decode_connect(client_id: String) -> BytesBuilder {
  // Only set clean session for now
  let connect_bits = <<1:4, 0:4>>
  let connect_flags = 0b10

  let variable_header =
    bytes_builder.new()
    |> bytes_builder.append(encode.string("MQTT"))
    |> bytes_builder.append(<<
      protocol_level:8,
      connect_flags:8,
      keep_alive_seconds:big-size(16),
    >>)

  let variable_content =
    variable_header
    |> bytes_builder.append(encode.string(client_id))
  // More strings to be added here

  let remaining_len = bytes_builder.byte_size(variable_content)
  let fixed_header =
    bit_array.append(connect_bits, encode.varint(remaining_len))

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
