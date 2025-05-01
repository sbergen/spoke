//// Outgoing packets for a MQTT server.
//// Note that these are currently used only for testing,
//// but I might split the packets into a separate packages at some point.

import gleam/bytes_tree.{type BytesTree}
import spoke/packet.{type ConnAckResult, type PublishData, type SubscribeResult}
import spoke/packet/encode.{type EncodeError}

pub type Packet {
  ConnAck(ConnAckResult)
  Publish(PublishData)
  PubAck(packet_id: Int)
  PubRec(packet_id: Int)
  PubRel(packet_id: Int)
  PubComp(packet_id: Int)
  SubAck(packet_id: Int, return_codes: List(SubscribeResult))
  UnsubAck(packet_id: Int)
  PingResp
}

pub fn encode_packet(packet: Packet) -> Result(BytesTree, EncodeError) {
  case packet {
    ConnAck(result) -> Ok(encode.connack(result))
    Publish(data) -> Ok(encode.publish(data))
    PubAck(packet_id) -> Ok(encode.only_packet_id(4, 0, packet_id))
    PubRec(packet_id) -> Ok(encode.only_packet_id(5, 0, packet_id))
    PubRel(packet_id) -> Ok(encode.only_packet_id(6, 2, packet_id))
    PubComp(packet_id) -> Ok(encode.only_packet_id(7, 0, packet_id))
    SubAck(packet_id, results) -> encode.suback(packet_id, results)
    UnsubAck(packet_id) -> Ok(encode.only_packet_id(11, 0, packet_id))
    PingResp -> Ok(encode.only_packet_type(13))
  }
}
