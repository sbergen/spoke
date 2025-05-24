# spoke_packet

[![Package Version](https://img.shields.io/hexpm/v/spoke_packet)](https://hex.pm/packages/spoke_packet)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/spoke_packet/)

`spoke_packet` contains Gleam data structures to represent MQTT packets
and encode/decode them to/from their binary representation.
The data structures strive to be make representing invalid states impossible,
which is why they sometimes might feel a bit far from their binary representations.

```sh
gleam add spoke_packet@1
```
```gleam
import gleam/bytes_tree
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/client/outgoing

pub fn main() {
  // Represent MQTT packets in code
  let subscribe_packet =
    outgoing.Subscribe(
      packet_id: 42,
      topic: packet.SubscribeRequest("my/topic", packet.QoS1),
      other_topics: [],
    )

  // And encode them into binary. Prints
  // <<130, 13, 0, 42, 0, 8, 109, 121, 47, 116, 111, 112, 105, 99, 1>>
  let bytes = outgoing.encode_packet(subscribe_packet)
  echo bytes_tree.to_bit_array(bytes)

  // Decode binary data, which may contain multiple packets or be incomplete:
  let assert Ok(#(packets, rest)) =
    incoming.decode_packets(<<32, 2, 0, 1, 64, 2, 0, 42, 208>>)

  // As there was two full packets in the data, prints
  // [ConnAck(Error(UnacceptableProtocolVersion)), PubAck(42)]
  echo packets

  // As the third packet was incomplete, prints <<208>>
  echo rest
}
```
