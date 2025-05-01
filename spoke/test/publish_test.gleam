import fake_server
import gleam/erlang/process
import spoke.{AtMostOnce}
import spoke/packet.{SessionNotPresent, SessionPresent}
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub fn publish_qos0_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  spoke.publish(client, data)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected = server_in.Publish(packet.PublishDataQoS0(expected_msg))
  fake_server.expect_packet(server, expected)

  fake_server.disconnect(client, server)
}

pub fn publish_qos1_success_flow_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.AtLeastOnce, False)
  spoke.publish(client, data)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected =
    server_in.Publish(packet.PublishDataQoS1(
      expected_msg,
      dup: False,
      packet_id: 1,
    ))
  fake_server.expect_packet(server, expected)

  let assert 1 = spoke.pending_publishes(client)
    as "the packet shouldn't be considered sent before the ACK"

  fake_server.send_response(server, server_out.PubAck(1))

  let assert Ok(Nil) = spoke.wait_for_publishes_to_finish(client, 10)
    as "the packet should be considered sent after the ACK"

  fake_server.disconnect(client, server)
}

pub fn resend_qos1_after_disconnected_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: False)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.AtLeastOnce, False)
  spoke.publish(client, data)

  let server = fake_server.close_connection(server)
  // Consume disconnect update:
  let assert Ok(_) = process.receive(spoke.updates(client), 100)

  let server = fake_server.reconnect(client, server, False, SessionPresent)

  // Expect re-transmission after reconnect, since no ack was received
  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected =
    server_in.Publish(packet.PublishDataQoS1(
      expected_msg,
      dup: True,
      packet_id: 1,
    ))
  let server = fake_server.expect_packet(server, expected)

  let assert 1 = spoke.pending_publishes(client)
    as "the packet shouldn't be considered sent before the ACK"

  fake_server.send_response(server, server_out.PubAck(1))

  let assert Ok(Nil) = spoke.wait_for_publishes_to_finish(client, 100)
    as "the packet should be considered sent after the ACK"

  fake_server.disconnect(client, server)
}

pub fn publish_qos2_happy_path_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.ExactlyOnce, False)
  spoke.publish(client, data)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected =
    server_in.Publish(packet.PublishDataQoS2(
      expected_msg,
      dup: False,
      packet_id: 1,
    ))
  let server = fake_server.expect_packet(server, expected)

  let assert 1 = spoke.pending_publishes(client)
  fake_server.send_response(server, server_out.PubRec(1))
  let assert 1 = spoke.pending_publishes(client)
  let server = fake_server.expect_packet(server, server_in.PubRel(1))
  let assert 1 = spoke.pending_publishes(client)

  fake_server.send_response(server, server_out.PubComp(1))

  let assert Ok(Nil) = spoke.wait_for_publishes_to_finish(client, 100)
    as "the packet should be considered sent after PubComp"

  fake_server.disconnect(client, server)
}

pub fn publish_qos2_resend_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: False)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.ExactlyOnce, False)
  spoke.publish(client, data)

  // Disconnect and reconnect
  let server = fake_server.close_connection(server)
  // Consume disconnect update:
  let assert Ok(_) = process.receive(spoke.updates(client), 100)
  let server = fake_server.reconnect(client, server, False, SessionPresent)

  // Should resend after reconnecting
  let expected =
    server_in.Publish(packet.PublishDataQoS2(
      packet.MessageData(data.topic, data.payload, retain: data.retain),
      dup: True,
      packet_id: 1,
    ))
  let server = fake_server.expect_packet(server, expected)
  fake_server.send_response(server, server_out.PubRec(1))
  let server = fake_server.expect_packet(server, server_in.PubRel(1))
  fake_server.send_response(server, server_out.PubComp(1))

  let assert Ok(Nil) = spoke.wait_for_publishes_to_finish(client, 100)

  fake_server.disconnect(client, server)
}

pub fn publish_qos2_rerelease_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: False)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.ExactlyOnce, False)
  spoke.publish(client, data)
  let server = fake_server.expect_any_packet(server)
  fake_server.send_response(server, server_out.PubRec(1))

  // Disconnect and reconnect
  let server = fake_server.close_connection(server)
  // Consume disconnect update:
  let assert Ok(_) = process.receive(spoke.updates(client), 100)
  let server = fake_server.reconnect(client, server, False, SessionPresent)

  let server = fake_server.expect_packet(server, server_in.PubRel(1))
  fake_server.send_response(server, server_out.PubComp(1))

  let assert Ok(Nil) = spoke.wait_for_publishes_to_finish(client, 100)

  fake_server.disconnect(client, server)
}

pub fn clean_session_after_disconnected_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: False)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.AtLeastOnce, False)
  spoke.publish(client, data)

  let server = fake_server.close_connection(server)
  // Consume disconnect update:
  let assert Ok(_) = process.receive(spoke.updates(client), 100)

  let server = fake_server.reconnect(client, server, True, SessionNotPresent)

  let assert 0 = spoke.pending_publishes(client)
    as "the packet should be discarded, when clean_session is set to True"

  fake_server.disconnect(client, server)
}

pub fn previous_clean_session_is_discarded_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.AtLeastOnce, False)
  spoke.publish(client, data)

  let server = fake_server.close_connection(server)
  // Consume disconnect update:
  let assert Ok(_) = process.receive(spoke.updates(client), 100)

  let server = fake_server.reconnect(client, server, False, SessionNotPresent)

  let assert 0 = spoke.pending_publishes(client)
    as "the packet should be discarded, when clean_session was set to True in previous session"

  fake_server.disconnect(client, server)
}

pub fn wait_for_publishes_timeout_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  let data = spoke.PublishData("topic", <<"payload">>, spoke.AtLeastOnce, False)
  spoke.publish(client, data)

  let assert Error(Nil) = spoke.wait_for_publishes_to_finish(client, 10)
    as "waiting for publishes should time out if not acked"

  fake_server.drop_incoming_data(server)
  fake_server.disconnect(client, server)
}
