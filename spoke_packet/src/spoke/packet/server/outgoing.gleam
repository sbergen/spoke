//// Outgoing packets for a MQTT server.

import gleam/bytes_tree.{type BytesTree}
import spoke/packet.{type ConnAckResult, type PublishData, type SubscribeResult}
import spoke/packet/internal/encode

/// Represents all the valid outgoing packets for an MQTT server.
pub type Packet {
  ConnAck(ConnAckResult)
  Publish(PublishData)
  PubAck(packet_id: Int)
  PubRec(packet_id: Int)
  PubRel(packet_id: Int)
  PubComp(packet_id: Int)
  // Empty return codes list is not allowed
  SubAck(
    packet_id: Int,
    return_code: SubscribeResult,
    other_return_codes: List(SubscribeResult),
  )
  UnsubAck(packet_id: Int)
  PingResp
}

/// Encodes a packet into its binary form.
pub fn encode_packet(packet: Packet) -> BytesTree {
  case packet {
    ConnAck(result) -> encode.connack(result)
    Publish(data) -> encode.publish(data)
    PubAck(packet_id) -> encode.only_packet_id(4, 0, packet_id)
    PubRec(packet_id) -> encode.only_packet_id(5, 0, packet_id)
    PubRel(packet_id) -> encode.only_packet_id(6, 2, packet_id)
    PubComp(packet_id) -> encode.only_packet_id(7, 0, packet_id)
    SubAck(packet_id, result, other_results) ->
      encode.suback(packet_id, result, other_results)
    UnsubAck(packet_id) -> encode.only_packet_id(11, 0, packet_id)
    PingResp -> encode.only_packet_type(13)
  }
}
