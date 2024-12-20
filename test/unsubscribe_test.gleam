import fake_server
import gleam/erlang/process
import gleam/otp/task
import spoke
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn unsubscribe_success_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let topics = ["topic0", "topic1"]

  let subscribe = task.async(fn() { spoke.unsubscribe(client, topics) })
  fake_server.expect_packet(socket, server_in.Unsubscribe(1, topics))
  fake_server.send_response(socket, server_out.UnsubAck(1))

  let assert Ok(Ok(Nil)) = task.try_await(subscribe, 10)

  fake_server.disconnect(client, updates, socket)
}

pub fn unsubscribe_invalid_id_test() {
  let #(client, updates, socket) =
    fake_server.set_up_connected_client_with_timeout(5)

  let unsubscribe = task.async(fn() { spoke.unsubscribe(client, ["topic0"]) })
  fake_server.expect_any_packet(socket)
  fake_server.send_response(socket, server_out.UnsubAck(42))

  // This will have to be a timeout, as we don't know which subject to respond to
  let assert Ok(Error(spoke.OperationTimedOut)) =
    task.try_await(unsubscribe, 10)

  let assert Ok(spoke.DisconnectedUnexpectedly(
    "Received invalid packet id in unsubscribe ack",
  )) = process.receive(updates, 0)
}

pub fn unsubscribe_timed_out_test() {
  let #(client, updates, _socket) =
    fake_server.set_up_connected_client_with_timeout(5)

  let unsubscribe = task.async(fn() { spoke.unsubscribe(client, ["topic0"]) })

  let assert Ok(Error(spoke.OperationTimedOut)) =
    task.try_await(unsubscribe, 10)
  let assert Ok(spoke.DisconnectedUnexpectedly(_)) = process.receive(updates, 0)
}
