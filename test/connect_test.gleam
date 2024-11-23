import fake_server
import gleam/erlang/process
import gleam/otp/task
import gleeunit/should
import spoke
import spoke/internal/packet
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out
import spoke/internal/transport
import test_client

pub fn connect_disconnect_test() {
  let #(client, updates, state, received_data, result) =
    fake_server.connect_specific(Ok(False), "test-client-id", 42)

  result |> should.equal(Ok(False))
  received_data.client_id |> should.equal("test-client-id")
  received_data.keep_alive |> should.equal(42)

  fake_server.disconnect(client, updates, state.socket)
}

pub fn reconnect_after_rejected_connect_test() {
  let #(client, updates, state, result) =
    fake_server.connect_with_response(Error(packet.BadUsernameOrPassword))

  result |> should.equal(Error(spoke.BadUsernameOrPassword))
  // There should be nothing to be done here,
  // as the server should close the connection

  let #(state, result) = fake_server.reconnect(client, state.listener, Ok(True))
  result |> should.equal(Ok(True))

  fake_server.disconnect(client, updates, state.socket)
}

pub fn aborted_connect_disconnects_with_correct_status_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, _updates) = fake_server.start_client_with_defaults(port)

  let connect_task = task.async(fn() { spoke.connect(client, 100) })
  let socket = fake_server.expect_connection_established(listener)
  spoke.disconnect(client)

  let assert Ok(Error(spoke.DisconnectRequested)) =
    task.try_await(connect_task, 10)

  fake_server.drop_incoming_data(socket)
  fake_server.expect_connection_closed(socket)
}

pub fn timed_out_connect_disconnects_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, updates) = fake_server.start_client_with_defaults(port)

  // The timeout used for connect is what matters (server timeout does not)
  let connect_task = task.async(fn() { spoke.connect(client, 2) })
  let socket = fake_server.expect_connection_established(listener)
  let assert Error(spoke.ConnectTimedOut) = task.await(connect_task, 5)

  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
  fake_server.drop_incoming_data(socket)
  fake_server.expect_connection_closed(socket)
}

pub fn connecting_when_already_connected_fails_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, updates) = fake_server.start_client_with_defaults(port)

  // Start first connect
  let initial_connect = task.async(fn() { spoke.connect(client, 100) })
  let socket = fake_server.expect_connection_established(listener)

  // Start overlapping connect
  let assert Error(spoke.AlreadyConnected) = spoke.connect(client, 10)

  // Finish initial connect
  fake_server.drop_incoming_data(socket)
  fake_server.send_response(socket, server_out.ConnAck(Ok(False)))
  let assert Ok(Ok(False)) = task.try_await(initial_connect, 10)

  fake_server.disconnect(client, updates, socket)
}

pub fn channel_error_on_connect_fails_connect_test() {
  let #(client, _updates) = fake_server.start_client_with_defaults(9999)
  let connect_task = task.async(fn() { spoke.connect(client, 100) })
  let assert Error(spoke.ConnectChannelError("ConnectFailed(\"Econnrefused\")")) =
    task.await(connect_task, 100)
}

pub fn channel_error_after_establish_fails_connect_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, _updates) = fake_server.start_client_with_defaults(port)

  let connect_task = task.async(fn() { spoke.connect(client, 100) })
  fake_server.reject_connection(listener)

  let assert Error(spoke.ConnectChannelError("SendFailed(\"Closed\")")) =
    task.await(connect_task, 100)
}
