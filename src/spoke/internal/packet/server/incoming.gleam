//// Incoming packets for a MQTT server.
//// Note that these are currently used only for testing,
//// but I might split the packets into a separate packages at some point.

import spoke/internal/packet.{type PublishData, type SubscribeRequest}

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
