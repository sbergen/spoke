import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}
import packet/encode

const protocol_level: Int = 4

const keep_alive_seconds: Int = 60

pub type PacketType {
  Connect
  ConnAck
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

pub fn connect(client_id: String) -> BytesBuilder {
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
