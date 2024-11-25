import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Subject}
import gleam/result
import gleam/string
import gleeunit/should
import glisten/socket.{type ListenSocket, type Socket}
import glisten/socket/options.{ActiveMode, Passive}
import glisten/tcp
import spoke
import spoke/internal/packet
import spoke/internal/packet/server/incoming
import spoke/internal/packet/server/outgoing

const default_timeout = 100

pub type ConnectedState {
  ConnectedState(listener: ListenSocket, socket: Socket)
}

pub type ReceivedConnectData {
  ReceivedConnectData(client_id: String, keep_alive: Int)
}

/// Good default for most tests
pub fn set_up_connected_client() -> #(
  spoke.Client,
  Subject(spoke.Update),
  Socket,
) {
  let #(listener, port) = start_server()

  let updates = process.new_subject()
  let client =
    spoke.start_with_ms_keep_alive(
      "ping-client",
      15,
      100,
      default_options(port),
      updates,
    )

  let #(state, _, _) = connect_client(client, updates, listener, Ok(False))

  #(client, updates, state.socket)
}

pub fn start_server() -> #(ListenSocket, Int) {
  let assert Ok(listener) = tcp.listen(0, [ActiveMode(Passive)])
  let assert Ok(#(_, port)) = tcp.sockname(listener)
  #(listener, port)
}

pub fn default_options(port: Int) {
  spoke.TcpOptions("localhost", port, connect_timeout: 100)
}

/// Runs the full client connect process and returns the given response
pub fn connect_client(
  client: spoke.Client,
  updates: Subject(spoke.Update),
  listener: ListenSocket,
  response: Result(Bool, packet.ConnectError),
) -> #(ConnectedState, Result(Bool, spoke.ConnectError), ReceivedConnectData) {
  let assert Ok(Nil) = spoke.connect(client, default_timeout)

  let #(state, details) = expect_connect(listener)
  send_response(state.socket, outgoing.ConnAck(response))

  // If a server sends a CONNACK packet containing a non-zero return code
  // it MUST then close the Network Connection
  case result.is_error(response) {
    True -> close_connection(state.socket)
    False -> Nil
  }

  let assert Ok(update) = process.receive(updates, default_timeout)
  let connect_result = case update {
    spoke.Connected(session_present) -> Ok(session_present)
    spoke.ConnectionFailed(e) -> Error(e)
    _ -> panic as "Unexpected update while connecting"
  }

  #(state, connect_result, details)
}

pub fn reconnect(
  client: spoke.Client,
  updates: Subject(spoke.Update),
  listener: ListenSocket,
  response: Result(Bool, packet.ConnectError),
) -> #(ConnectedState, Result(Bool, spoke.ConnectError)) {
  let #(state, result, _) = connect_client(client, updates, listener, response)
  #(state, result)
}

// Receives whatever is available, and drops the data
pub fn drop_incoming_data(socket: Socket) -> Nil {
  let _ = tcp.receive_timeout(socket, 0, default_timeout)
  Nil
}

pub fn assert_no_incoming_data(socket: Socket) -> Nil {
  let assert Error(socket.Timeout) = tcp.receive_timeout(socket, 0, 1)
  Nil
}

pub fn expect_packet_matching(
  socket: Socket,
  predicate: fn(incoming.Packet) -> Bool,
) -> Nil {
  let received_packet = receive_packet(socket, default_timeout)
  case predicate(received_packet) {
    True -> Nil
    False ->
      panic as {
        "Received packet did not match expectation: "
        <> string.inspect(receive_packet)
      }
  }
}

pub fn expect_packet(socket: Socket, expected_packet: incoming.Packet) -> Nil {
  expect_packet_timeout(socket, default_timeout, expected_packet)
}

pub fn expect_packet_timeout(
  socket: Socket,
  timeout: Int,
  expected_packet: incoming.Packet,
) -> Nil {
  let received_packet = receive_packet(socket, timeout)
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

pub fn send_raw_response(socket: Socket, data: BytesTree) -> Nil {
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
  expect_connection_closed_with_limit(10, socket)
}

fn expect_connection_closed_with_limit(try_index: Int, socket: Socket) -> Nil {
  case try_index {
    0 ->
      panic as "Too many incoming packets when expecting connection to be closed"
    _ ->
      case tcp.receive_timeout(socket, 0, default_timeout) {
        Ok(_) -> expect_connection_closed_with_limit(try_index - 1, socket)
        Error(e) -> e |> should.equal(socket.Closed)
      }
  }
}

/// Runs a clean disconnect on the client
pub fn disconnect(
  client: spoke.Client,
  updates: Subject(spoke.Update),
  socket: Socket,
) -> Nil {
  spoke.disconnect(client)

  let assert Ok(spoke.DisconnectedExpectedly) =
    process.receive(updates, default_timeout)

  expect_packet(socket, incoming.Disconnect)
  let assert Ok(_) = tcp.shutdown(socket)
  Nil
}

fn receive_packet(socket: Socket, timeout: Int) -> incoming.Packet {
  let assert Ok(data) = tcp.receive_timeout(socket, 0, timeout)
  let assert Ok(#(packet, <<>>)) = incoming.decode_packet(data)
  packet
}

/// Expects a TCP connect & connect packet
fn expect_connect(
  listener: ListenSocket,
) -> #(ConnectedState, ReceivedConnectData) {
  let socket = expect_connection_established(listener)
  let packet = receive_packet(socket, default_timeout)

  case packet {
    incoming.Connect(options) -> #(
      ConnectedState(listener, socket),
      ReceivedConnectData(options.client_id, options.keep_alive_seconds),
    )
    _ -> panic as { "expected Connect, got: " <> string.inspect(packet) }
  }
}
