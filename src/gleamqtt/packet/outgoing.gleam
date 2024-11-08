import gleam/bytes_builder.{type BytesBuilder}
import gleam/list
import gleam/option.{type Option}
import gleamqtt.{type QoS, type SubscribeTopic, QoS0, QoS1, QoS2}
import gleamqtt/packet/encode
import gleamqtt/packet/errors.{type EncodeError}

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
  PingReq
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
  Unsubscribe
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

fn encode_qos(qos: QoS) -> BitArray {
  <<
    case qos {
      gleamqtt.QoS0 -> 0
      gleamqtt.QoS1 -> 1
      gleamqtt.QoS2 -> 2
    },
  >>
}
