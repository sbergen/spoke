import fake_server
import gleam/erlang/process
import spoke
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn receive_message_qos0_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS0(msg)

  fake_server.send_response(socket, server_out.Publish(data))

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(updates, 10)

  fake_server.disconnect(client, updates, socket)
}

pub fn receive_message_qos1_happy_path_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS1(msg, dup: False, packet_id: 42)

  fake_server.send_response(socket, server_out.Publish(data))

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(updates, 10)

  fake_server.expect_packet(socket, server_in.PubAck(42))

  fake_server.disconnect(client, updates, socket)
}
