//// Incoming packets for a MQTT client

import spoke/packet.{
  type ConnAckResult, type DecodeError, type PublishData, type SubscribeResult,
}
import spoke/packet/internal/decode

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

/// Decodes all packets from a chunk of binary data.
/// Returns a list of decoded packets and the leftover data,
/// or the first error if the data is invalid.
pub fn decode_all(
  bytes: BitArray,
) -> Result(#(List(Packet), BitArray), DecodeError) {
  decode.all(bytes, decode_packet)
}

/// Decodes a single packet from a chunk of binary data.
/// Returns the decoded packet and the leftover data,
/// or the first error if the data is invalid.
pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        2 -> decode.connack(flags, rest, ConnAck)
        3 -> decode.publish(flags, rest, Publish)
        4 -> decode.only_packet_id(flags, rest, 0, PubAck)
        5 -> decode.only_packet_id(flags, rest, 0, PubRec)
        6 -> decode.only_packet_id(flags, rest, 2, PubRel)
        7 -> decode.only_packet_id(flags, rest, 0, PubComp)
        9 -> decode.suback(flags, rest, SubAck)
        11 -> decode.only_packet_id(flags, rest, 0, UnsubAck)
        13 -> decode.zero_length(flags, rest, PingResp)
        _ -> Error(packet.InvalidPacketIdentifier(id))
      }
    _ -> Error(packet.DataTooShort)
  }
}
