import fake_server
import gleam/bytes_tree
import gleam/erlang/process
import spoke
import spoke/internal/packet
import spoke/internal/packet/server/outgoing as server_out

pub fn multiple_packets_at_once_test() {
  let #(client, socket) = fake_server.set_up_connected_client(True)

  let assert Ok(data) = server_out.encode_packet(default_publish())
  let two_publishes = bytes_tree.concat([data, data])

  fake_server.send_raw_response(socket, two_publishes)

  let updates = spoke.updates(client)

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(updates, 10)

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(updates, 10)

  fake_server.disconnect(client, socket)
}

pub fn split_packets_test() {
  let #(client, socket) = fake_server.set_up_connected_client(True)

  let assert Ok(data) = server_out.encode_packet(default_publish())
  let assert <<begin:bytes-size(5), end:bytes>> = bytes_tree.to_bit_array(data)

  fake_server.send_raw_response(socket, bytes_tree.from_bit_array(begin))
  fake_server.send_raw_response(socket, bytes_tree.from_bit_array(end))

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(spoke.updates(client), 10)

  fake_server.disconnect(client, socket)
}

fn default_publish() -> server_out.Packet {
  let message =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  server_out.Publish(packet.PublishDataQoS0(message))
}
