import spoke/internal/packet.{
  type ConnAckResult, type PublishData, type SubscribeResult,
}
import spoke/internal/packet/decode.{type DecodeError}

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

pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        0 -> Error(decode.InvalidPacketIdentifier)
        2 -> decode.connack(flags, rest, ConnAck)
        3 -> decode.publish(flags, rest, Publish)
        9 -> decode.suback(flags, rest, SubAck)
        13 -> decode.pingresp(flags, rest, PingResp)
        _ -> Error(decode.DecodeNotImplemented)
      }
    _ -> Error(decode.DataTooShort)
  }
}
