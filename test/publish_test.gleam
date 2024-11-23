import fake_server
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import glisten/socket.{type Socket}
import spoke.{AtMostOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in

pub fn publish_qos0_test() {
  let #(client, updates, socket) = set_up_connected()

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  let assert Ok(_) = spoke.publish(client, data, 10)

  let expected =
    server_in.Publish(packet.PublishData(
      "topic",
      <<"payload">>,
      False,
      packet.QoS0,
      False,
      None,
    ))
  fake_server.expect_packet(socket, expected)

  fake_server.disconnect(client, updates, socket)
}

pub fn publish_timeout_disconnects_test() {
  let #(client, updates, socket) = set_up_connected()

  let data = spoke.PublishData("topic", <<>>, AtMostOnce, False)
  let assert Error(spoke.PublishTimedOut) = spoke.publish(client, data, 0)

  // TODO: Rethink if publish should really have a timeout,
  // or if we should use the server_timeout value instead.
  fake_server.drop_incoming_data(socket)
  fake_server.expect_connection_closed(socket)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

fn set_up_connected() -> #(spoke.Client, Subject(spoke.Update), Socket) {
  let #(listener, port) = fake_server.start_server()

  let updates = process.new_subject()
  let client =
    spoke.start_with_sub_second_keep_alive(
      "ping-client",
      15,
      100,
      fake_server.default_options(port),
      updates,
    )

  let #(state, _, _) = fake_server.connect_client(client, listener, Ok(False))

  #(client, updates, state.socket)
}
