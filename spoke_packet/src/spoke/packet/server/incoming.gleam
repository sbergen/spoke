//// Incoming packets for a MQTT server.
//// Note that these are currently used only for testing,
//// but I might split the packets into a separate packages at some point.

import spoke/packet.{
  type ConnectOptions, type DecodeError, type PublishData, type SubscribeRequest,
}
import spoke/packet/internal/decode

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
        1 -> decode.connect(flags, rest, Connect)
        3 -> decode.publish(flags, rest, Publish)
        4 -> decode.only_packet_id(flags, rest, 0, PubAck)
        5 -> decode.only_packet_id(flags, rest, 0, PubRec)
        6 -> decode.only_packet_id(flags, rest, 2, PubRel)
        7 -> decode.only_packet_id(flags, rest, 0, PubComp)
        8 -> decode.subscribe(flags, rest, Subscribe)
        10 -> decode.unsubscribe(flags, rest, Unsubscribe)
        12 -> decode.zero_length(flags, rest, PingReq)
        14 -> decode.zero_length(flags, rest, Disconnect)
        _ -> Error(packet.InvalidPacketIdentifier(id))
      }
    _ -> Error(packet.DataTooShort)
  }
}
