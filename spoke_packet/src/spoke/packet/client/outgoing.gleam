//// Outgoing packets for a MQTT client

import gleam/bytes_tree.{type BytesTree}
import spoke/packet.{
  type ConnectOptions, type EncodeError, type PublishData, type SubscribeRequest,
}
import spoke/packet/internal/encode

pub type Packet {
  Connect(ConnectOptions)
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
    Connect(data) -> Ok(encode.connect(data))
    Publish(data) -> Ok(encode.publish(data))
    PubAck(packet_id) -> Ok(encode.only_packet_id(4, 0, packet_id))
    PubRec(packet_id) -> Ok(encode.only_packet_id(5, 0, packet_id))
    PubRel(packet_id) -> Ok(encode.only_packet_id(6, 2, packet_id))
    PubComp(packet_id) -> Ok(encode.only_packet_id(7, 0, packet_id))
    Subscribe(packet_id, topics) -> encode.subscribe(packet_id, topics)
    Unsubscribe(packet_id, topics) -> encode.unsubscribe(packet_id, topics)
    PingReq -> Ok(encode.only_packet_type(12))
    Disconnect -> Ok(encode.only_packet_type(14))
  }
}
