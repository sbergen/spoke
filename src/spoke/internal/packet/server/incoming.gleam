import spoke/internal/packet.{type PublishData, type SubscribeRequest}

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
