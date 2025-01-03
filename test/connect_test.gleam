import fake_server.{type ConnectedState, type ReceivedConnectData}
import gleam/erlang/process.{type Subject}
import gleeunit/should
import spoke.{ConnectionStateChanged}
import spoke/internal/packet
import spoke/internal/packet/server/outgoing as server_out

const default_client_id = "fake-client-id"

pub fn connect_and_disconnect_test() {
  let #(client, updates, state, result, details) =
    connect(Ok(False), "test-client-id", 42)

  details.client_id |> should.equal("test-client-id")
  details.keep_alive |> should.equal(42)
  result |> should.equal(Ok(False))

  fake_server.disconnect(client, updates, state.socket)
}

pub fn reconnect_after_rejected_connect_test() {
  let #(client, updates, state, result, _details) =
    connect(Error(packet.BadUsernameOrPassword), default_client_id, 10)

  result |> should.equal(Error(spoke.BadUsernameOrPassword))

  let #(state, result) =
    fake_server.reconnect(client, updates, state.listener, Ok(True))
  result |> should.equal(Ok(True))

  fake_server.disconnect(client, updates, state.socket)
}

pub fn aborted_connect_disconnects_expectedly_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, updates) = start_client_with_defaults(port)

  spoke.connect(client)

  let socket = fake_server.expect_connection_established(listener)
  spoke.disconnect(client)

  let assert Ok(ConnectionStateChanged(spoke.Disconnected)) =
    process.receive(updates, 10)

  fake_server.expect_connection_closed(socket)
}

pub fn connecting_when_already_connected_succeeds_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, updates) = start_client_with_defaults(port)

  // Start first connect
  spoke.connect(client)
  let socket = fake_server.expect_connection_established(listener)

  // Start overlapping connect
  spoke.connect(client)

  // Finish initial connect
  fake_server.drop_incoming_data(socket)
  fake_server.send_response(socket, server_out.ConnAck(Ok(False)))
  let assert Ok(ConnectionStateChanged(spoke.ConnectAccepted(False))) =
    process.receive(updates, 10)

  fake_server.disconnect(client, updates, socket)
}

pub fn channel_error_on_connect_fails_connect_test() {
  let #(client, updates) = start_client_with_defaults(9999)

  let _ = spoke.connect(client)

  let assert Ok(ConnectionStateChanged(spoke.ConnectFailed(_))) =
    process.receive(updates, 10)
}

pub fn channel_error_after_establish_fails_connect_test() {
  let #(listener, port) = fake_server.start_server()
  let #(client, updates) = start_client_with_defaults(port)

  spoke.connect(client)
  fake_server.reject_connection(listener)

  let assert Ok(ConnectionStateChanged(spoke.ConnectFailed(_))) =
    process.receive(updates, 10)
}

pub fn timed_out_connect_test() {
  let #(listener, port) = fake_server.start_server()
  let connect_opts = spoke.ConnectOptions(default_client_id, 10, 5)
  let updates = process.new_subject()
  let client =
    spoke.start(connect_opts, fake_server.default_options(port), updates)
  spoke.connect(client)

  fake_server.expect_connection_established(listener)

  let assert Ok(ConnectionStateChanged(spoke.ConnectFailed(_))) =
    process.receive(updates, 10)
}

fn connect(
  response: Result(Bool, packet.ConnectError),
  client_id: String,
  keep_alive: Int,
) -> #(
  spoke.Client,
  Subject(spoke.Update),
  ConnectedState,
  Result(Bool, spoke.ConnectError),
  ReceivedConnectData,
) {
  let #(listener, port) = fake_server.start_server()

  let connect_opts = spoke.ConnectOptions(client_id, keep_alive, 100)
  let updates = process.new_subject()
  let client =
    spoke.start(connect_opts, fake_server.default_options(port), updates)

  let #(state, connect_result, details) =
    fake_server.connect_client(client, updates, listener, response)

  #(client, updates, state, connect_result, details)
}

fn start_client_with_defaults(
  port: Int,
) -> #(spoke.Client, Subject(spoke.Update)) {
  let connect_opts = spoke.ConnectOptions(default_client_id, 10, 100)
  let updates = process.new_subject()
  let client =
    spoke.start(connect_opts, fake_server.default_options(port), updates)
  #(client, updates)
}
