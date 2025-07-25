import drift/record
import gleam/bytes_tree
import gleam/list
import gleam/option.{None}
import spoke/core.{Connect, Handle, Perform, ReceivedData, TransportEstablished}
import spoke/core/recorder
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn multiple_packets_at_connect_test() {
  let bits =
    packets_to_bits([
      server_out.ConnAck(Ok(packet.SessionPresent)),
      server_out.Publish(
        packet.PublishDataQoS0(packet.MessageData(
          topic: "topic",
          payload: <<"payload">>,
          retain: False,
        )),
      ),
    ])

  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> record.input(Handle(ReceivedData(bits)))
  |> recorder.snap("Receiving multiple packets in first chunk of data")
}

pub fn multiple_packets_after_connect_test() {
  let bits =
    packets_to_bits([
      server_out.Publish(
        packet.PublishDataQoS0(packet.MessageData(
          topic: "topic",
          payload: <<"payload">>,
          retain: False,
        )),
      ),
      server_out.Publish(
        packet.PublishDataQoS0(packet.MessageData(
          topic: "topic2",
          payload: <<"payload2">>,
          retain: False,
        )),
      ),
    ])

  recorder.default_connected()
  |> record.input(Handle(ReceivedData(bits)))
  |> recorder.snap("Receiving multiple packets after connected")
}

pub fn split_packet_test() {
  let packet =
    server_out.Publish(
      packet.PublishDataQoS0(packet.MessageData(
        topic: "topic",
        payload: <<"payload">>,
        retain: False,
      )),
    )
  let assert <<begin:bytes-size(5), end:bytes>> =
    bytes_tree.to_bit_array(server_out.encode_packet(packet))

  recorder.default_connected()
  |> record.input(Handle(ReceivedData(begin)))
  |> record.input(Handle(ReceivedData(end)))
  |> recorder.snap("Receiving packet in split chunks")
}

fn packets_to_bits(packets: List(server_out.Packet)) -> BitArray {
  packets
  |> list.map(server_out.encode_packet)
  |> bytes_tree.concat
  |> bytes_tree.to_bit_array
}
