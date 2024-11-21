import gleam/bytes_tree.{type BytesTree}
import spoke/internal/packet.{type PublishData, type SubscribeRequest}
import spoke/internal/packet/encode.{type EncodeError}

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

pub fn encode_packet(packet: Packet) -> Result(BytesTree, EncodeError) {
  case packet {
    Connect(client_id, keep_alive) -> Ok(encode.connect(client_id, keep_alive))
    Disconnect -> Ok(encode.disconnect())
    Subscribe(id, topics) -> encode.subscribe(id, topics)
    PingReq -> Ok(encode.ping_req())
    Publish(data) -> Ok(encode.publish(data))
    _ -> Error(encode.EncodeNotImplemented)
  }
}
