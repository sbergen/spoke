import fake_server
import gleam/erlang/process
import gleam/option.{None}
import spoke.{AtMostOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in

pub fn publish_qos0_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  let assert Ok(_) = spoke.publish(client, data, 10)

  let expected_msg =
    packet.MessageData("topic", <<"payload">>, packet.QoS0, retain: False)
  let expected =
    server_in.Publish(packet.PublishData(
      expected_msg,
      dup: False,
      packet_id: None,
    ))
  fake_server.expect_packet(socket, expected)

  fake_server.disconnect(client, updates, socket)
}

pub fn publish_timeout_disconnects_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let data = spoke.PublishData("topic", <<>>, AtMostOnce, False)
  let assert Error(spoke.PublishTimedOut) = spoke.publish(client, data, 0)

  // TODO: Rethink if publish should really have a timeout,
  // or if we should use the server_timeout value instead.
  fake_server.drop_incoming_data(socket)
  fake_server.expect_connection_closed(socket)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}
