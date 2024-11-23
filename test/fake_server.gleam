import gleam/erlang/process.{type Subject}
import gleam/otp/task
import gleam/string
import gleeunit/should
import glisten/socket.{type ListenSocket, type Socket}
import glisten/socket/options.{ActiveMode, Passive}
import glisten/tcp
import spoke
import spoke/internal/packet/server/incoming
import spoke/internal/packet/server/outgoing

const default_timeout = 100

pub type ConnectedState {
  ConnectedState(listener: ListenSocket, socket: Socket)
}

pub type ReceivedConnectData {
  ReceivedConnectData(client_id: String, keep_alive: Int)
}

pub fn connect_specific(
  session_preset: Bool,
  client_id: String,
  keep_alive: Int,
) -> #(spoke.Client, Subject(spoke.Update), ConnectedState, ReceivedConnectData) {
  let #(listener, port) = start_server()

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

  let connect_task = task.async(fn() { spoke.connect(client, default_timeout) })
  let #(result, details) = expect_connect(listener)

  send_response(result.socket, outgoing.ConnAck(Ok(session_preset)))
  let assert Ok(Ok(returned_session_present)) =
    task.try_await(connect_task, default_timeout)
  returned_session_present |> should.equal(session_preset)

  #(client, updates, result, details)
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

pub fn disconnect(
  client: spoke.Client,
  updates: Subject(spoke.Update),
  state: ConnectedState,
) {
  spoke.disconnect(client)

  // TODO: This is not ideal, should we make disconnect use send instead of call?
  let assert Ok(spoke.Disconnected) = process.receive(updates, default_timeout)

  expect_packet(state.socket, incoming.Disconnect)
  //let assert Ok(_) = tcp.shutdown(state.socket)
  //let assert Ok(_) = tcp.close(state.listener)
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
  let assert Ok(socket) = tcp.accept_timeout(listener, default_timeout)
  let packet = receive_packet(socket)

  case packet {
    incoming.Connect(client_id, keep_alive) -> #(
      ConnectedState(listener, socket),
      ReceivedConnectData(client_id, keep_alive),
    )
    _ -> panic as { "expected Connect, got: " <> string.inspect(packet) }
  }
}

fn start_server() -> #(ListenSocket, Int) {
  let assert Ok(listener) = tcp.listen(8000, [ActiveMode(Passive)])
  let assert Ok(#(_, port)) = tcp.sockname(listener)
  #(listener, port)
}
