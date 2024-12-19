import fake_server
import gleam/erlang/process
import spoke.{AtMostOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in

pub fn publish_qos0_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  let assert Ok(Nil) = spoke.publish(client, data, 10)

  let expected_msg = packet.MessageData("topic", <<"payload">>, retain: False)
  let expected = server_in.Publish(packet.PublishDataQoS0(expected_msg))
  fake_server.expect_packet(socket, expected)

  fake_server.disconnect(client, updates, socket)
}

pub fn publish_timeout_disconnects_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<>>, AtMostOnce, False)
  let assert Error(spoke.PublishTimedOut) = spoke.publish(client, data, 0)

  // TODO: Rethink if publish should really have a timeout,
  // or if we should use the server_timeout value instead.
  // TODO: This is not expected
  // See https://github.com/gleam-lang/otp/pull/88
  fake_server.expect_connection_closed(socket)
  let assert Ok(spoke.DisconnectedExpectedly) = process.receive(updates, 1)
}
