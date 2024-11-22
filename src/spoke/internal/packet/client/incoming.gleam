import spoke/internal/packet.{
  type ConnAckResult, type PublishData, type SubscribeResult,
}
import spoke/internal/packet/decode.{type DecodeError}

pub type Packet {
  ConnAck(ConnAckResult)
  Publish(PublishData)
  PubAck(packet_id: Int)
  PubRec(packet_id: Int)
  PubRel(packet_id: Int)
  PubComp(packet_id: Int)
  SubAck(packet_id: Int, return_codes: List(SubscribeResult))
  UnsubAck
  PingResp
}

pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        2 -> decode.connack(flags, rest, ConnAck)
        3 -> decode.publish(flags, rest, Publish)
        4 -> decode.pub_qos(flags, rest, PubAck)
        5 -> decode.pub_qos(flags, rest, PubRec)
        6 -> decode.pub_qos(flags, rest, PubRel)
        7 -> decode.pub_qos(flags, rest, PubComp)
        9 -> decode.suback(flags, rest, SubAck)
        11 -> todo as "unsuback"
        13 -> decode.pingresp(flags, rest, PingResp)
        _ -> Error(decode.InvalidPacketIdentifier(id))
      }
    _ -> Error(decode.DataTooShort)
  }
}
