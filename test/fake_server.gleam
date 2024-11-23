import gleam/erlang/process.{type Subject}
import gleam/otp/task
import gleam/result
import gleam/string
import glisten/socket.{type ListenSocket, type Socket}
import glisten/socket/options.{ActiveMode, Passive}
import glisten/tcp
import spoke
import spoke/internal/packet
import spoke/internal/packet/server/incoming
import spoke/internal/packet/server/outgoing

const default_timeout = 100

const default_client_id = "client-id"

const default_keep_alive = 10

pub type ConnectedState {
  ConnectedState(listener: ListenSocket, socket: Socket)
}

pub type ReceivedConnectData {
  ReceivedConnectData(client_id: String, keep_alive: Int)
}

/// Connects with the given response, other details are defaults
pub fn connect_with_response(
  response: Result(Bool, packet.ConnectError),
) -> #(
  spoke.Client,
  Subject(spoke.Update),
  ConnectedState,
  Result(Bool, spoke.ConnectError),
) {
  let #(client, updates, state, _, result) =
    connect_specific(response, default_client_id, default_keep_alive)
  #(client, updates, state, result)
}

/// The most customized way to connect
pub fn connect_specific(
  connect_response: Result(Bool, packet.ConnectError),
  client_id: String,
  keep_alive: Int,
) -> #(
  spoke.Client,
  Subject(spoke.Update),
  ConnectedState,
  ReceivedConnectData,
  Result(Bool, spoke.ConnectError),
) {
  let #(listener, port) = start_server()
  let #(client, updates) = start_client_with(port, client_id, keep_alive)
  let #(state, connect_result, details) =
    do_connect_with_details(client, listener, connect_response)

  #(client, updates, state, details, connect_result)
}

pub fn start_server() -> #(ListenSocket, Int) {
  let assert Ok(listener) = tcp.listen(0, [ActiveMode(Passive)])
  let assert Ok(#(_, port)) = tcp.sockname(listener)
  #(listener, port)
}

pub fn start_client_with_defaults(
  port: Int,
) -> #(spoke.Client, Subject(spoke.Update)) {
  start_client_with(port, default_client_id, default_keep_alive)
}

pub fn reconnect(
  client: spoke.Client,
  listener: ListenSocket,
  response: Result(Bool, packet.ConnectError),
) -> #(ConnectedState, Result(Bool, spoke.ConnectError)) {
  let #(state, result, _) = do_connect_with_details(client, listener, response)
  #(state, result)
}

// Receives whatever is available, and drops the data
pub fn drop_incoming_data(socket: Socket) -> Nil {
  // Short timeout here, let's see if it's stable...
  let _ = tcp.receive_timeout(socket, 0, 1)
  Nil
}

pub fn expect_packet(socket: Socket, expected_packet: incoming.Packet) -> Nil {
  let received_packet = receive_packet(socket)
  case received_packet == expected_packet {
    True -> Nil
    False ->
      panic as {
        "expected "
        <> string.inspect(expect_packet)
        <> ", got: "
        <> string.inspect(received_packet)
      }
  }
}

pub fn send_response(socket: Socket, packet: outgoing.Packet) -> Nil {
  let assert Ok(data) = outgoing.encode_packet(packet)
  let assert Ok(_) = tcp.send(socket, data)
  Nil
}

pub fn expect_connection_established(listener: ListenSocket) -> Socket {
  let assert Ok(socket) = tcp.accept_timeout(listener, default_timeout)
  socket
}

// Listens for a connection and immediately drops it
pub fn reject_connection(listener: ListenSocket) -> Nil {
  let assert Ok(socket) = tcp.accept_timeout(listener, default_timeout)
  let assert Ok(_) = tcp.shutdown(socket)
  Nil
}

pub fn close_connection(socket: Socket) -> Nil {
  let assert Ok(_) = tcp.shutdown(socket)
  Nil
}

pub fn expect_connection_closed(socket: Socket) -> Nil {
  let assert Error(socket.Closed) =
    tcp.receive_timeout(socket, 0, default_timeout)
  Nil
}

/// Runs a clean disconnect on the client
pub fn disconnect(
  client: spoke.Client,
  updates: Subject(spoke.Update),
  socket: Socket,
) {
  spoke.disconnect(client)

  // TODO: This is not ideal, should we make disconnect use send instead of call?
  let assert Ok(spoke.Disconnected) = process.receive(updates, default_timeout)

  expect_packet(socket, incoming.Disconnect)
  let assert Ok(_) = tcp.shutdown(socket)
}

/// Runs the full client connect process and returns the given response
fn do_connect_with_details(
  client: spoke.Client,
  listener: ListenSocket,
  response: Result(Bool, packet.ConnectError),
) -> #(ConnectedState, Result(Bool, spoke.ConnectError), ReceivedConnectData) {
  let connect_task = task.async(fn() { spoke.connect(client, default_timeout) })
  let #(state, details) = expect_connect(listener)

  send_response(state.socket, outgoing.ConnAck(response))

  // If a server sends a CONNACK packet containing a non-zero return code
  // it MUST then close the Network Connection
  case result.is_error(response) {
    True -> close_connection(state.socket)
    False -> Nil
  }

  let assert Ok(connect_result) = task.try_await(connect_task, default_timeout)
  #(state, connect_result, details)
}

/// Configures options and starts the client
fn start_client_with(
  port: Int,
  client_id: String,
  keep_alive: Int,
) -> #(spoke.Client, Subject(spoke.Update)) {
  let connect_opts =
    spoke.ConnectOptions(
      client_id,
      keep_alive_seconds: keep_alive,
      server_timeout_ms: default_timeout,
    )
  let transport_opts =
    spoke.TcpOptions("localhost", port, connect_timeout: default_timeout)
  let updates = process.new_subject()
  let client = spoke.start(connect_opts, transport_opts, updates)

  #(client, updates)
}

fn receive_packet(socket: Socket) -> incoming.Packet {
  let assert Ok(data) = tcp.receive_timeout(socket, 0, default_timeout)
  let assert Ok(#(packet, <<>>)) = incoming.decode_packet(data)
  packet
}

/// Expects a TCP connect & connect packet
fn expect_connect(
  listener: ListenSocket,
) -> #(ConnectedState, ReceivedConnectData) {
  let socket = expect_connection_established(listener)
  let packet = receive_packet(socket)

  case packet {
    incoming.Connect(client_id, keep_alive) -> #(
      ConnectedState(listener, socket),
      ReceivedConnectData(client_id, keep_alive),
    )
    _ -> panic as { "expected Connect, got: " <> string.inspect(packet) }
  }
}
