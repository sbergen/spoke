import fake_server
import spoke.{AtMostOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in

pub fn publish_qos0_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  let assert Ok(Nil) = spoke.publish(client, data)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected = server_in.Publish(packet.PublishDataQoS0(expected_msg))
  fake_server.expect_packet(socket, expected)

  fake_server.disconnect(client, updates, socket)
}
// Since QoS0 doesn't have puback, we can't test timeouts with it
