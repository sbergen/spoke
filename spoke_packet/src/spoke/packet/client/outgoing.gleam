//// Outgoing packets for a MQTT client

import gleam/bytes_tree.{type BytesTree}
import spoke/packet.{
  type ConnectOptions, type PublishData, type SubscribeRequest,
}
import spoke/packet/internal/encode

/// Represents all the valid outgoing packets for an MQTT client.
pub type Packet {
  Connect(ConnectOptions)
  Publish(PublishData)
  PubAck(packet_id: Int)
  PubRec(packet_id: Int)
  PubRel(packet_id: Int)
  PubComp(packet_id: Int)
  // At least one topic is required when subscribing
  Subscribe(
    packet_id: Int,
    topic: SubscribeRequest,
    other_topics: List(SubscribeRequest),
  )
  // At least one topic is required when unsubscribing
  Unsubscribe(packet_id: Int, topic: String, other_topics: List(String))
  PingReq
  Disconnect
}

/// Encodes a packet into its binary form.
pub fn encode_packet(packet: Packet) -> BytesTree {
  case packet {
    Connect(data) -> encode.connect(data)
    Publish(data) -> encode.publish(data)
    PubAck(packet_id) -> encode.only_packet_id(4, 0, packet_id)
    PubRec(packet_id) -> encode.only_packet_id(5, 0, packet_id)
    PubRel(packet_id) -> encode.only_packet_id(6, 2, packet_id)
    PubComp(packet_id) -> encode.only_packet_id(7, 0, packet_id)
    Subscribe(packet_id, topic, other_topics) ->
      encode.subscribe(packet_id, topic, other_topics)
    Unsubscribe(packet_id, topic, other_topics) ->
      encode.unsubscribe(packet_id, topic, other_topics)
    PingReq -> encode.only_packet_type(12)
    Disconnect -> encode.only_packet_type(14)
  }
}
