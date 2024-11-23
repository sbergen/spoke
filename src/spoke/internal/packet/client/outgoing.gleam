import gleam/bytes_tree.{type BytesTree}
import spoke/internal/packet.{type PublishData, type SubscribeRequest}
import spoke/internal/packet/encode.{type EncodeError}

pub type Packet {
  Connect(client_id: String, keep_alive: Int)
  Publish(PublishData)
  PubAck(packet_id: Int)
  PubRec(packet_id: Int)
  PubRel(packet_id: Int)
  PubComp(packet_id: Int)
  Subscribe(packet_id: Int, topics: List(SubscribeRequest))
  Unsubscribe(packet_id: Int, topics: List(String))
  PingReq
  Disconnect
}

pub fn encode_packet(packet: Packet) -> Result(BytesTree, EncodeError) {
  case packet {
    Connect(client_id, keep_alive) -> Ok(encode.connect(client_id, keep_alive))
    Publish(data) -> Ok(encode.publish(data))
    PubAck(packet_id) -> Ok(encode.only_packet_id(4, packet_id))
    PubRec(packet_id) -> Ok(encode.only_packet_id(5, packet_id))
    PubRel(packet_id) -> Ok(encode.only_packet_id(6, packet_id))
    PubComp(packet_id) -> Ok(encode.only_packet_id(7, packet_id))
    Subscribe(packet_id, topics) -> encode.subscribe(packet_id, topics)
    Unsubscribe(packet_id, topics) -> encode.unsubscribe(packet_id, topics)
    PingReq -> Ok(encode.ping_req())
    Disconnect -> Ok(encode.disconnect())
  }
}
