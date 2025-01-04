import fake_server
import gleam/erlang/process
import gleam/otp/task
import spoke.{ConnectionStateChanged}
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn subscribe_when_not_connected_returns_error_test() {
  let client =
    spoke.start(
      spoke.ConnectOptions("client-id", 10, 100),
      fake_server.default_options(1883),
    )

  let assert Error(spoke.NotConnected) = spoke.unsubscribe(client, ["topic"])
}

pub fn unsubscribe_success_test() {
  let #(client, socket) = fake_server.set_up_connected_client(True)

  let topics = ["topic0", "topic1"]

  let subscribe = task.async(fn() { spoke.unsubscribe(client, topics) })
  fake_server.expect_packet(socket, server_in.Unsubscribe(1, topics))
  fake_server.send_response(socket, server_out.UnsubAck(1))

  let assert Ok(Ok(Nil)) = task.try_await(subscribe, 10)

  fake_server.disconnect(client, socket)
}

pub fn unsubscribe_invalid_id_test() {
  let #(client, socket) =
    fake_server.set_up_connected_client_with_timeout(True, 5)

  let unsubscribe = task.async(fn() { spoke.unsubscribe(client, ["topic0"]) })
  fake_server.expect_any_packet(socket)
  fake_server.send_response(socket, server_out.UnsubAck(42))

  // This will have to be a timeout, as we don't know which subject to respond to
  let assert Ok(Error(spoke.OperationTimedOut)) =
    task.try_await(unsubscribe, 10)

  let assert Ok(ConnectionStateChanged(spoke.DisconnectedUnexpectedly(
    "Received invalid packet id in unsubscribe ack",
  ))) = process.receive(spoke.updates(client), 0)
}

pub fn unsubscribe_timed_out_test() {
  let #(client, _socket) =
    fake_server.set_up_connected_client_with_timeout(True, 5)

  let unsubscribe = task.async(fn() { spoke.unsubscribe(client, ["topic0"]) })

  let assert Ok(Error(spoke.OperationTimedOut)) =
    task.try_await(unsubscribe, 10)
  let assert Ok(ConnectionStateChanged(spoke.DisconnectedUnexpectedly(_))) =
    process.receive(spoke.updates(client), 10)
}
