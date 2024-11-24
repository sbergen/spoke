//// Incoming packets for a MQTT server.
//// Note that these are currently used only for testing,
//// but I might split the packets into a separate packages at some point.

import spoke/internal/packet.{
  type ConnectOptions, type PublishData, type SubscribeRequest,
}
import spoke/internal/packet/decode.{type DecodeError}

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

pub fn decode_packet(
  bytes: BitArray,
) -> Result(#(Packet, BitArray), DecodeError) {
  case bytes {
    <<id:4, flags:bits-size(4), rest:bytes>> ->
      case id {
        1 -> decode.connect(flags, rest, Connect)
        3 -> decode.publish(flags, rest, Publish)
        4 -> decode.only_packet_id(flags, rest, PubAck)
        5 -> decode.only_packet_id(flags, rest, PubRec)
        6 -> decode.only_packet_id(flags, rest, PubRel)
        7 -> decode.only_packet_id(flags, rest, PubComp)
        8 -> decode.subscribe(flags, rest, Subscribe)
        10 -> decode.unsubscribe(flags, rest, Unsubscribe)
        12 -> decode.zero_length(flags, rest, PingReq)
        14 -> decode.zero_length(flags, rest, Disconnect)
        _ -> Error(decode.InvalidPacketIdentifier(id))
      }
    _ -> Error(decode.DataTooShort)
  }
}
