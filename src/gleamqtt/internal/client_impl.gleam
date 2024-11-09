import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamqtt.{type ConnectOptions, type Update}
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/internal/transport/channel.{type EncodedChannel}
import gleamqtt/transport.{type ChannelResult}

pub opaque type ClientImpl {
  ClientImpl(subject: Subject(ClientMsg))
}

pub fn run(
  options: ConnectOptions,
  connect: fn() -> EncodedChannel,
  updates: Subject(Update),
) -> ClientImpl {
  let state = ClientState(options, connect, updates, Disconnected)
  let assert Ok(client) = actor.start(state, run_client)
  process.send(client, Connect)
  ClientImpl(client)
}

type ClientState {
  ClientState(
    options: ConnectOptions,
    connect: fn() -> EncodedChannel,
    updates: Subject(Update),
    conn_state: ConnectionState,
  )
}

type ClientMsg {
  Connect
  Received(ChannelResult(incoming.Packet))
}

type ConnectionState {
  Disconnected
  ConnectingToServer(EncodedChannel)
  Connected(EncodedChannel)
}

fn run_client(
  msg: ClientMsg,
  state: ClientState,
) -> actor.Next(ClientMsg, ClientState) {
  case msg {
    Connect -> connect(state)
    Received(r) -> handle_receive(state, r)
  }
}

fn connect(state: ClientState) -> actor.Next(ClientMsg, ClientState) {
  let assert Disconnected = state.conn_state
  let channel = state.connect()

  let receives = process.new_subject()
  let new_selector =
    process.new_selector()
    |> process.selecting(receives, Received(_))
  channel.start_receive(receives)

  let connect_packet =
    outgoing.Connect(state.options.client_id, state.options.keep_alive)
  let assert Ok(_) = channel.send(connect_packet)

  let new_state = ClientState(..state, conn_state: ConnectingToServer(channel))
  actor.with_selector(actor.continue(new_state), new_selector)
}

fn handle_receive(
  state: ClientState,
  data: ChannelResult(incoming.Packet),
) -> actor.Next(ClientMsg, ClientState) {
  let assert Ok(packet) = data

  case packet {
    incoming.ConnAck(session_present, status) ->
      handle_connack(state, session_present, status)
    _ -> todo as "Packet type not handled"
  }
}

fn handle_connack(
  state: ClientState,
  session_present: Bool,
  status: gleamqtt.ConnectReturnCode,
) -> actor.Next(ClientMsg, ClientState) {
  let assert ConnectingToServer(connection) = state.conn_state

  process.send(state.updates, gleamqtt.ConnectFinished(status, session_present))

  case status {
    gleamqtt.ConnectionAccepted ->
      actor.continue(ClientState(..state, conn_state: Connected(connection)))
    _ -> todo as "Should disconnect"
  }
}
