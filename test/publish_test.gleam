import fake_server
import spoke.{AtMostOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn publish_qos0_test() {
  let #(client, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  spoke.publish(client, data)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected = server_in.Publish(packet.PublishDataQoS0(expected_msg))
  fake_server.expect_packet(socket, expected)

  fake_server.disconnect(client, socket)
}

pub fn publish_qos0_success_flow_test() {
  let #(client, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<"payload">>, spoke.AtLeastOnce, False)
  spoke.publish(client, data)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected =
    server_in.Publish(packet.PublishDataQoS1(
      expected_msg,
      dup: False,
      packet_id: 1,
    ))
  fake_server.expect_packet(socket, expected)

  let assert 1 = spoke.pending_publishes(client)
    as "the packet shouldn't be considered sent before the ACK"

  fake_server.send_response(socket, server_out.PubAck(1))

  let assert Ok(Nil) = spoke.wait_for_publishes_to_finish(client, 10)
    as "the packet should be considered sent after the ACK"

  fake_server.disconnect(client, socket)
}
