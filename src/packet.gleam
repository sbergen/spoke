import encode
import gleam/bytes_builder

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

pub fn connect() -> BitArray {
  let variable_header =
    bytes_builder.new()
    |> bytes_builder.append(encode.string("MQTT"))
  let var_header_len = bytes_builder.byte_size(variable_header)

  let fixed_header =
    bytes_builder.new()
    |> bytes_builder.append(<<1:4, 0:4>>)
    |> bytes_builder.append(encode.varint(var_header_len))

  bytes_builder.concat([fixed_header, variable_header])
  |> bytes_builder.to_bit_array()
}
