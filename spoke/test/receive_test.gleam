import fake_server
import gleam/erlang/process
import spoke
import spoke/packet
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

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

pub fn receive_message_qos2_duplicate_filtering_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: False)

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS2(msg, dup: False, packet_id: 42)

  fake_server.send_response(server, server_out.Publish(data))
  let server = fake_server.close_connection(server)

  // Consume updates
  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(spoke.updates(client), 10)
  let assert Ok(spoke.ConnectionStateChanged(spoke.DisconnectedUnexpectedly(_))) =
    process.receive(spoke.updates(client), 10)

  // Reconnect
  let #(server, _) =
    fake_server.connect_client(client, server, False, packet.SessionPresent)

  // Re-send data, as we didn't receive the PubRec
  let data = packet.PublishDataQoS2(msg, dup: True, packet_id: 42)
  fake_server.send_response(server, server_out.Publish(data))

  fake_server.expect_packet(server, server_in.PubRec(42))
  fake_server.send_response(server, server_out.PubRel(42))
  fake_server.expect_packet(server, server_in.PubComp(42))

  fake_server.disconnect(client, server)
}

pub fn receive_message_qos2_duplicate_pubrel_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: False)

  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS2(msg, dup: False, packet_id: 42)

  fake_server.send_response(server, server_out.Publish(data))
  fake_server.expect_packet(server, server_in.PubRec(42))
  fake_server.send_response(server, server_out.PubRel(42))
  let server = fake_server.close_connection(server)

  // Consume updates
  let assert Ok(spoke.ReceivedMessage("topic", <<"payload">>, False)) =
    process.receive(spoke.updates(client), 10)
  let assert Ok(spoke.ConnectionStateChanged(spoke.DisconnectedUnexpectedly(_))) =
    process.receive(spoke.updates(client), 10)

  // Reconnect
  let #(server, _) =
    fake_server.connect_client(client, server, False, packet.SessionPresent)

  fake_server.send_response(server, server_out.PubRel(42))
  fake_server.expect_packet(server, server_in.PubComp(42))

  fake_server.disconnect(client, server)
}
