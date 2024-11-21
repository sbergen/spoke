import spoke/internal/packet.{
  type ConnAckResult, type PublishData, type SubscribeResult,
}

pub type Packet {
  ConnAck(ConnAckResult)
  PingResp
  Publish(PublishData)
  PubAck
  PubRec
  PubRel
  PubComp
  SubAck(packet_id: Int, return_codes: List(SubscribeResult))
  UnsubAck
}
