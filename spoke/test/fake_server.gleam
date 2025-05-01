import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit/should
import glisten/socket.{type ListenSocket, type Socket}
import glisten/socket/options.{ActiveMode, Passive}
import glisten/tcp
import spoke
import spoke/internal/session
import spoke/packet.{SessionNotPresent, SessionPresent}
import spoke/packet/decode
import spoke/packet/server/incoming
import spoke/packet/server/outgoing
import spoke/tcp as spoke_tcp

const default_timeout = 200

pub type ListeningServer {
  ListeningServer(listener: ListenSocket, port: Int)
}

pub type ConnectedServer {
  ConnectedServer(server: ListeningServer, socket: Socket, leftover: BitArray)
}

/// Good default for most tests
pub fn set_up_connected_client(
  clean_session clean_session: Bool,
) -> #(spoke.Client, ConnectedServer) {
  set_up_connected_client_with_timeout(clean_session, 100)
}

pub fn set_up_connected_client_with_timeout(
  clean_session: Bool,
  timeout: Int,
) -> #(spoke.Client, ConnectedServer) {
  let server = start_server()

  let client =
    spoke.start_session_with_ms_keep_alive(
      session.new(True),
      "ping-client",
      None,
      1000,
      timeout,
      default_connector(server.port),
    )

  let #(server, _) =
    connect_client(client, server, clean_session, SessionNotPresent)

  #(client, server)
}

pub fn start_server() -> ListeningServer {
  let assert Ok(listener) = tcp.listen(0, [ActiveMode(Passive)])
  let assert Ok(#(_, port)) = tcp.sockname(listener)
  ListeningServer(listener, port)
}

pub fn default_connector(port: Int) {
  spoke_tcp.connector("localhost", port, connect_timeout: default_timeout)
}

/// Runs the full client connect process and returns the given response
pub fn connect_client(
  client: spoke.Client,
  server: ListeningServer,
  clean_session: Bool,
  session_present: packet.SessionPresence,
) -> #(ConnectedServer, packet.ConnectOptions) {
  spoke.connect(client, clean_session)

  let #(server, details) = expect_connect(server)
  send_response(server, outgoing.ConnAck(Ok(session_present)))

  let assert Ok(update) =
    process.receive(spoke.updates(client), default_timeout)

  let connection_state = case update {
    spoke.ConnectionStateChanged(state) -> state
    _ ->
      panic as {
        "Unexpected update while connecting: " <> string.inspect(update)
      }
  }

  let is_session_present = case connection_state {
    spoke.ConnectAccepted(session_present) -> session_present
    _ ->
      panic as {
        "Unexpected connection change while connecting: "
        <> string.inspect(connection_state)
      }
  }

  is_session_present
  |> should.equal(case session_present {
    SessionNotPresent -> False
    SessionPresent -> True
  })

  #(server, details)
}

pub fn connect_client_with_error(
  client: spoke.Client,
  server: ListeningServer,
  error: packet.ConnectError,
) -> #(ListeningServer, spoke.ConnectError, packet.ConnectOptions) {
  spoke.connect(client, False)

  let #(server, details) = expect_connect(server)
  send_response(server, outgoing.ConnAck(Error(error)))

  // If a server sends a CONNACK packet containing a non-zero return code
  // it MUST then close the Network Connection
  let server = close_connection(server)

  let assert Ok(update) =
    process.receive(spoke.updates(client), default_timeout)
  let connection_state = case update {
    spoke.ConnectionStateChanged(state) -> state
    _ ->
      panic as {
        "Unexpected update while connecting: " <> string.inspect(update)
      }
  }

  let connect_result = case connection_state {
    spoke.ConnectRejected(e) -> e
    _ ->
      panic as {
        "Unexpected connection change while connecting: "
        <> string.inspect(connection_state)
      }
  }

  #(server, connect_result, details)
}

pub fn reconnect(
  client: spoke.Client,
  server: ListeningServer,
  clean_session: Bool,
  session_present: packet.SessionPresence,
) -> ConnectedServer {
  let #(server, _) =
    connect_client(client, server, clean_session, session_present)
  server
}

// Receives whatever is available, and drops the data
pub fn drop_incoming_data(server: ConnectedServer) -> Nil {
  let _ = tcp.receive_timeout(server.socket, 0, default_timeout)
  Nil
}

pub fn assert_no_incoming_data(server: ConnectedServer) -> Nil {
  let assert Error(socket.Timeout) = tcp.receive_timeout(server.socket, 0, 1)
  Nil
}

pub fn expect_packet_matching(
  server: ConnectedServer,
  predicate: fn(incoming.Packet) -> Bool,
) -> ConnectedServer {
  let #(server, received_packet) = receive_packet(server, default_timeout)
  case predicate(received_packet) {
    True -> server
    False ->
      panic as {
        "Received packet did not match expectation: "
        <> string.inspect(received_packet)
      }
  }
}

pub fn expect_packet(
  server: ConnectedServer,
  expected_packet: incoming.Packet,
) -> ConnectedServer {
  expect_packet_timeout(server, default_timeout, expected_packet)
}

pub fn expect_any_packet(server: ConnectedServer) -> ConnectedServer {
  let #(server, _) = receive_packet(server, default_timeout)
  server
}

pub fn expect_packet_timeout(
  server: ConnectedServer,
  timeout: Int,
  expected_packet: incoming.Packet,
) -> ConnectedServer {
  let #(server, received_packet) = receive_packet(server, timeout)
  case received_packet == expected_packet {
    True -> server
    False ->
      panic as {
        "expected "
        <> string.inspect(expected_packet)
        <> ", got: "
        <> string.inspect(received_packet)
      }
  }
}

pub fn send_response(server: ConnectedServer, packet: outgoing.Packet) -> Nil {
  let assert Ok(data) = outgoing.encode_packet(packet)
  let assert Ok(_) = tcp.send(server.socket, data)
  Nil
}

pub fn send_raw_response(server: ConnectedServer, data: BytesTree) -> Nil {
  let assert Ok(_) = tcp.send(server.socket, data)
  Nil
}

pub fn expect_connection_established(server: ListeningServer) -> ConnectedServer {
  let assert Ok(socket) = tcp.accept_timeout(server.listener, default_timeout)
  ConnectedServer(server, socket, <<>>)
}

// Listens for a connection and immediately drops it
pub fn reject_connection(server: ListeningServer) -> Nil {
  let assert Ok(socket) = tcp.accept_timeout(server.listener, default_timeout)
  let assert Ok(_) = tcp.shutdown(socket)
  Nil
}

pub fn close_connection(server: ConnectedServer) -> ListeningServer {
  let assert Ok(_) = tcp.shutdown(server.socket)
  server.server
}

pub fn expect_connection_closed(server: ConnectedServer) -> ListeningServer {
  expect_connection_closed_with_limit(10, server)
}

fn expect_connection_closed_with_limit(
  try_index: Int,
  server: ConnectedServer,
) -> ListeningServer {
  case try_index {
    0 ->
      panic as "Too many incoming packets when expecting connection to be closed"
    _ ->
      case tcp.receive_timeout(server.socket, 0, default_timeout) {
        Ok(_) -> expect_connection_closed_with_limit(try_index - 1, server)
        Error(e) -> {
          e |> should.equal(socket.Closed)
          server.server
        }
      }
  }
}

/// Runs a clean disconnect on the client
pub fn disconnect(
  client: spoke.Client,
  server: ConnectedServer,
) -> ListeningServer {
  spoke.disconnect(client)

  let assert Ok(spoke.ConnectionStateChanged(spoke.Disconnected)) =
    process.receive(spoke.updates(client), default_timeout)

  let server = expect_packet(server, incoming.Disconnect)
  let assert Ok(_) = tcp.shutdown(server.socket)
  server.server
}

fn receive_packet(
  server: ConnectedServer,
  timeout: Int,
) -> #(ConnectedServer, incoming.Packet) {
  case incoming.decode_packet(server.leftover) {
    Ok(#(packet, leftover)) -> #(ConnectedServer(..server, leftover:), packet)
    Error(decode.DataTooShort) -> {
      let assert Ok(new_data) = tcp.receive_timeout(server.socket, 0, timeout)
      let data = bit_array.append(server.leftover, new_data)
      let assert Ok(#(packet, leftover)) = incoming.decode_packet(data)
      #(ConnectedServer(..server, leftover:), packet)
    }
    error -> panic as { "Failed to decode packet: " <> string.inspect(error) }
  }
}

/// Expects a TCP connect & connect packet
fn expect_connect(
  server: ListeningServer,
) -> #(ConnectedServer, packet.ConnectOptions) {
  let connected = expect_connection_established(server)
  let packet = receive_packet(connected, default_timeout)

  case packet {
    #(server, incoming.Connect(options)) -> #(server, options)
    _ -> panic as { "expected Connect, got: " <> string.inspect(packet) }
  }
}
