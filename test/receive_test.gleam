import fake_server
import gleam/erlang/process
import spoke
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn receive_message_qos0_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS0(msg)

  fake_server.send_response(server, server_out.Publish(data))

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(spoke.updates(client), 10)

  fake_server.disconnect(client, server)
}

pub fn receive_message_qos1_happy_path_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS1(msg, dup: False, packet_id: 42)

  fake_server.send_response(server, server_out.Publish(data))

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(spoke.updates(client), 10)

  fake_server.expect_packet(server, server_in.PubAck(42))

  fake_server.disconnect(client, server)
}

pub fn receive_message_qos2_happy_path_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS2(msg, dup: False, packet_id: 42)

  fake_server.send_response(server, server_out.Publish(data))

  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(spoke.updates(client), 10)

  fake_server.expect_packet(server, server_in.PubRec(42))
  fake_server.send_response(server, server_out.PubRel(42))
  fake_server.expect_packet(server, server_in.PubComp(42))

  fake_server.disconnect(client, server)
}
