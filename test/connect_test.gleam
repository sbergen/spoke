import gleam/erlang/process
import gleam/otp/task
import gleeunit/should
import spoke
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import test_client

pub fn connect_success_test() {
  let keep_alive_s = 15
  let #(client, sent_packets, receives, _, _) =
    test_client.set_up_disconnected(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 1000) })

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request
  |> should.equal(outgoing.Connect(test_client.client_id, keep_alive_s))

  // Connect response
  test_client.simulate_server_response(receives, incoming.ConnAck(Ok(False)))

  let assert Ok(Ok(False)) = task.try_await(connect_task, 10)

  spoke.disconnect(client)
}

pub fn disconnects_after_server_rejects_connect_test() {
  let keep_alive_s = 15
  let #(client, _, receives, disconnects, updates) =
    test_client.set_up_disconnected(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 10) })

  // Connect response
  test_client.simulate_server_response(
    receives,
    incoming.ConnAck(Error(incoming.BadUsernameOrPassword)),
  )

  let assert Ok(Error(spoke.BadUsernameOrPassword)) =
    task.try_await(connect_task, 10)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn aborted_connect_disconnects_with_correct_status_test() {
  let #(client, _, receives, disconnects, updates) =
    test_client.set_up_disconnected(1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 10) })
  // Open channel
  let assert Ok(_) = process.receive(receives, 10)

  spoke.disconnect(client)

  let assert Ok(Error(spoke.DisconnectRequested)) =
    task.try_await(connect_task, 10)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn timed_out_connect_disconnects_test() {
  let #(client, _, _, disconnects, updates) =
    test_client.set_up_disconnected(1000, server_timeout: 100)

  // The timeout used for connect is what matters (server timeout does not)
  let assert Error(spoke.ConnectTimedOut) = spoke.connect(client, 2)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}
