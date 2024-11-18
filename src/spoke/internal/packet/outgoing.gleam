import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/list
import spoke/internal/packet.{type PublishData, type QoS, QoS0, QoS1, QoS2}
import spoke/internal/packet/encode.{type EncodeError}

const protocol_level: Int = 4

pub type Packet {
  Connect(client_id: String, keep_alive: Int)
  PingReq
  Publish(PublishData)
  PubAck
  PubRec
  PubRel
  PubComp
  Subscribe(packet_id: Int, topics: List(SubscribeRequest))
  Unsubscribe
  Disconnect
}

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}

pub type ConnectReturnCode {
  ConnectionAccepted
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub fn encode_packet(packet: Packet) -> Result(BytesTree, EncodeError) {
  case packet {
    Connect(client_id, keep_alive) -> Ok(encode_connect(client_id, keep_alive))
    Disconnect -> Ok(encode_disconnect())
    Subscribe(id, topics) -> encode_subscribe(id, topics)
    PingReq -> Ok(encode_ping_req())
    Publish(data) -> Ok(encode_publish(data))
    _ -> Error(encode.EncodeNotImplemented)
  }
}

fn encode_connect(client_id: String, keep_alive: Int) -> BytesTree {
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
    bytes_tree.new()
    |> bytes_tree.append(encode.string(client_id))
  // More strings to be added here

  encode_parts(1, <<0:4>>, header, payload)
}

fn encode_publish(data: packet.PublishData) -> BytesTree {
  let dup = bool.to_int(data.dup)
  let retain = bool.to_int(data.retain)
  let flags = <<dup:1, encode_qos(data.qos):2, retain:1>>
  // TODO packet id for QoS > 0
  let header = encode.string(data.topic)
  let payload = bytes_tree.from_bit_array(data.payload)
  encode_parts(3, flags, header, payload)
}

fn encode_subscribe(
  packet_id: Int,
  topics: List(SubscribeRequest),
) -> Result(BytesTree, EncodeError) {
  case topics {
    [] -> Error(encode.EmptySubscribeList)
    _ -> {
      let header = <<packet_id:big-size(16)>>
      let payload = {
        use builder, topic <- list.fold(topics, bytes_tree.new())
        builder
        |> bytes_tree.append(encode.string(topic.filter))
        |> bytes_tree.append(<<encode_qos(topic.qos):8>>)
      }

      Ok(encode_parts(8, <<2:4>>, header, payload))
    }
  }
}

fn encode_disconnect() -> BytesTree {
  encode_parts(14, flags: <<0:4>>, header: <<>>, payload: bytes_tree.new())
}

fn encode_ping_req() -> BytesTree {
  encode_parts(12, flags: <<0:4>>, header: <<>>, payload: bytes_tree.new())
}

fn encode_parts(
  id: Int,
  flags flags: BitArray,
  header header: BitArray,
  payload payload: BytesTree,
) {
  let variable_content =
    payload
    |> bytes_tree.prepend(header)
  let remaining_len = bytes_tree.byte_size(variable_content)
  let fixed_header = <<id:4, flags:bits, encode.varint(remaining_len):bits>>
  bytes_tree.prepend(variable_content, fixed_header)
}

fn encode_qos(qos: QoS) -> Int {
  case qos {
    QoS0 -> 0
    QoS1 -> 1
    QoS2 -> 2
  }
}
