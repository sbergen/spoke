import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import spoke.{type ConnectError, type QoS, type SubscribeRequest}
import spoke/internal/packet
import spoke/internal/packet/incoming.{type SubscribeResult}
import spoke/internal/packet/outgoing
import spoke/internal/transport/channel.{type EncodedChannel}
import spoke/internal/transport/tcp
import spoke/transport.{
  type ChannelError, type ChannelResult, type TransportOptions,
}

pub opaque type Client {
  Client(subject: Subject(ClientMsg))
}

pub type ConnectOptions {
  ConnectOptions(
    client_id: String,
    /// Keep-alive interval in seconds (MQTT spec doesn't allow more granular control)
    keep_alive_seconds: Int,
    /// "Reasonable amount of time" for the server to respond (including network latency),
    /// as used in the MQTT specification.
    server_timeout_ms: Int,
  )
}

pub type Update {
  ReceivedMessage(topic: String, payload: BitArray, retained: Bool)
  Disconnected
}

pub type PublishData {
  PublishData(topic: String, payload: BitArray, qos: QoS, retain: Bool)
}

pub type PublishError {
  PublishError(String)
}

pub type Subscription {
  SuccessfulSubscription(topic_filter: String, qos: QoS)
  FailedSubscription
}

pub type SubscribeError {
  // TODO more details here
  SubscribeError
}

/// Starts a new MQTT client with the given options
pub fn start(
  connect_opts: ConnectOptions,
  transport_opts: TransportOptions,
  updates: Subject(Update),
) -> Client {
  run(
    connect_opts.client_id,
    connect_opts.keep_alive_seconds * 1000,
    connect_opts.server_timeout_ms,
    fn() { create_channel(transport_opts) },
    updates,
  )
}

pub fn connect(
  client: Client,
  timeout timeout: Int,
) -> Result(Bool, ConnectError) {
  process.call(client.subject, Connect(_), timeout)
}

pub fn disconnect(client: Client) {
  process.send(client.subject, Disconnect)
}

pub fn publish(
  client: Client,
  data: PublishData,
  timeout: Int,
) -> Result(Nil, PublishError) {
  case process.try_call(client.subject, Publish(data, _), timeout) {
    Ok(result) -> result
    Error(e) -> Error(PublishError(string.inspect(e)))
  }
}

pub fn subscribe(
  client: Client,
  topics: List(SubscribeRequest),
  timeout: Int,
) -> Result(List(Subscription), SubscribeError) {
  case process.try_call(client.subject, Subscribe(topics, _), timeout) {
    Ok(result) -> Ok(result)
    Error(_) -> Error(SubscribeError)
  }
}

// Internal for testability:
// * EncodedChannel avoids having to encode packets we don't need to otherwise encode
// * keep_alive: allow sub-second keep-alive for faster tests
@internal
pub fn run(
  client_id: String,
  keep_alive_ms: Int,
  server_timeout_ms: Int,
  connect: fn() -> EncodedChannel,
  updates: Subject(Update),
) -> Client {
  let config = Config(client_id, keep_alive_ms, server_timeout_ms, connect)
  let assert Ok(client) =
    actor.start_spec(actor.Spec(fn() { init(config, updates) }, 100, run_client))
  Client(client)
}

/// Keep-alive interval in millisseconds
fn create_channel(options: TransportOptions) -> EncodedChannel {
  let assert Ok(raw_channel) = case options {
    transport.TcpOptions(host, port, connect_timeout, send_timeout) ->
      tcp.connect(host, port, connect_timeout, send_timeout)
  }
  channel.as_encoded(raw_channel)
}

type Config {
  Config(
    client_id: String,
    keep_alive: Int,
    server_timeout: Int,
    connect: fn() -> EncodedChannel,
  )
}

type ClientState {
  ClientState(
    self: Subject(ClientMsg),
    config: Config,
    updates: Subject(Update),
    conn_state: ConnectionState,
    packet_id: Int,
    pending_subs: Dict(Int, PendingSubscription),
  )
}

type ClientMsg {
  Connect(Subject(Result(Bool, ConnectError)))
  Publish(PublishData, Subject(Result(Nil, PublishError)))
  Subscribe(List(SubscribeRequest), Subject(List(Subscription)))
  Received(ChannelResult(incoming.Packet))
  Ping
  // TODO: Add disconnect reason
  Disconnect
}

type ConnectionState {
  NotConnected
  ConnectingToServer(EncodedChannel, Subject(Result(Bool, ConnectError)))
  Connected(
    channel: EncodedChannel,
    ping_timer: process.Timer,
    disconnect_timer: Option(process.Timer),
  )
}

type PendingSubscription {
  PendingSubscription(
    topics: List(SubscribeRequest),
    reply_to: Subject(List(Subscription)),
  )
}

fn init(
  config: Config,
  updates: Subject(Update),
) -> actor.InitResult(ClientState, ClientMsg) {
  let self = process.new_subject()

  let state = ClientState(self, config, updates, NotConnected, 1, dict.new())

  let selector =
    process.new_selector()
    |> process.selecting(self, function.identity)

  actor.Ready(state, selector)
}

fn run_client(
  msg: ClientMsg,
  state: ClientState,
) -> actor.Next(ClientMsg, ClientState) {
  case msg {
    Connect(reply_to) -> handle_connect(state, reply_to)
    Received(r) -> handle_receive(state, r)
    Publish(data, reply_to) -> handle_outgoing_publish(state, data, reply_to)
    Subscribe(topics, reply_to) -> handle_subscribe(state, topics, reply_to)
    Ping -> send_ping(state)
    Disconnect -> handle_disconnect(state)
  }
}

fn handle_connect(
  state: ClientState,
  reply_to: Subject(Result(Bool, ConnectError)),
) -> actor.Next(ClientMsg, ClientState) {
  let assert NotConnected = state.conn_state
  let channel = state.config.connect()

  let receives = process.new_subject()
  let new_selector =
    process.new_selector()
    |> process.selecting(state.self, function.identity)
    |> process.selecting(receives, Received(_))
  channel.start_receive(receives)

  let state =
    ClientState(..state, conn_state: ConnectingToServer(channel, reply_to))

  let config = state.config
  let connect_packet =
    outgoing.Connect(config.client_id, config.keep_alive / 1000)
  let assert Ok(state) = send_packet(state, connect_packet)

  actor.with_selector(actor.continue(state), new_selector)
}

fn handle_outgoing_publish(
  state: ClientState,
  data: PublishData,
  reply_to: Subject(Result(Nil, PublishError)),
) -> actor.Next(ClientMsg, ClientState) {
  let packet =
    outgoing.Publish(packet.PublishData(
      topic: data.topic,
      payload: data.payload,
      dup: False,
      qos: data.qos,
      retain: data.retain,
      packet_id: None,
    ))
  case send_packet(state, packet) {
    Ok(new_state) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }
    Error(e) -> {
      process.send(reply_to, Error(PublishError(string.inspect(e))))
      actor.continue(state)
    }
  }
}

fn handle_receive(
  state: ClientState,
  data: ChannelResult(incoming.Packet),
) -> actor.Next(ClientMsg, ClientState) {
  let assert Ok(packet) = data

  case packet {
    incoming.ConnAck(status) -> handle_connack(state, status)
    incoming.SubAck(id, results) -> handle_suback(state, id, results)
    incoming.Publish(data) -> handle_incoming_publish(state, data)
    incoming.PingResp -> handle_pingresp(state)
    _ -> todo as "Packet type not handled"
  }
}

fn handle_connack(
  state: ClientState,
  status: Result(Bool, spoke.ConnectError),
) -> actor.Next(ClientMsg, ClientState) {
  let assert ConnectingToServer(channel, reply_to) = state.conn_state

  process.send(reply_to, status)

  case status {
    Ok(_session_present) -> {
      let conn_state = Connected(channel, start_ping_timeout(state), None)
      actor.continue(ClientState(..state, conn_state: conn_state))
    }
    _ -> todo as "Should disconnect"
  }
}

fn handle_suback(
  state: ClientState,
  id: Int,
  results: List(SubscribeResult),
) -> actor.Next(ClientMsg, ClientState) {
  let subs = state.pending_subs
  let assert Ok(pending_sub) = dict.get(subs, id)
  let result = {
    // TODO: Validate result length?
    let pairs = list.zip(pending_sub.topics, results)
    use #(topic, result) <- list.map(pairs)
    case result {
      incoming.SubscribeSuccess(qos) ->
        SuccessfulSubscription(topic.filter, qos)
      incoming.SubscribeFailure -> FailedSubscription
    }
  }

  process.send(pending_sub.reply_to, result)
  actor.continue(ClientState(..state, pending_subs: dict.delete(subs, id)))
}

fn handle_subscribe(
  state: ClientState,
  topics: List(SubscribeRequest),
  reply_to: Subject(List(Subscription)),
) -> actor.Next(ClientMsg, ClientState) {
  let #(state, id) = reserve_packet_id(state)
  let pending_sub = PendingSubscription(topics, reply_to)
  let pending_subs = state.pending_subs |> dict.insert(id, pending_sub)

  let assert Ok(_) = send_packet(state, outgoing.Subscribe(id, topics))

  actor.continue(ClientState(..state, pending_subs: pending_subs))
}

fn handle_incoming_publish(
  state: ClientState,
  data: packet.PublishData,
) -> actor.Next(ClientMsg, ClientState) {
  let update = ReceivedMessage(data.topic, data.payload, data.retain)
  process.send(state.updates, update)
  actor.continue(state)
}

fn send_ping(state: ClientState) -> actor.Next(ClientMsg, ClientState) {
  case state.conn_state {
    // There can be some race conditions here, especially with our test values
    // Just ignore the ping if we are disconnected
    NotConnected -> actor.continue(state)
    ConnectingToServer(_, _) -> actor.continue(state)
    // TODO                  v this should be None
    Connected(channel, ping, _) -> {
      let assert process.TimerNotFound = process.cancel_timer(ping)
      let assert Ok(state) = send_packet(state, outgoing.PingReq)
      let disconnect =
        process.send_after(state.self, state.config.server_timeout, Disconnect)
      actor.continue(
        ClientState(
          ..state,
          conn_state: Connected(channel, ping, Some(disconnect)),
        ),
      )
    }
  }
}

fn handle_pingresp(state: ClientState) -> actor.Next(ClientMsg, ClientState) {
  let assert Connected(channel, ping, Some(disconnect)) = state.conn_state
  process.cancel_timer(disconnect)
  actor.continue(
    ClientState(..state, conn_state: Connected(channel, ping, None)),
  )
}

fn handle_disconnect(state: ClientState) -> actor.Next(ClientMsg, ClientState) {
  case state.conn_state {
    ConnectingToServer(channel, reply_to) -> {
      channel.shutdown()
      process.send(reply_to, Error(spoke.DisconnectRequested))
    }
    Connected(channel, ping, disconnect) -> {
      process.cancel_timer(ping)

      // Play it safe:
      case disconnect {
        Some(disconnect) -> process.cancel_timer(disconnect)
        None -> process.TimerNotFound
      }

      // TODO: other things to reset?

      channel.shutdown()
    }
    NotConnected -> Nil
  }

  process.send(state.updates, Disconnected)
  actor.continue(ClientState(..state, conn_state: NotConnected))
}

// Clients are allowed to send further Control Packets immediately after sending a CONNECT Packet;
// Clients need not wait for a CONNACK Packet to arrive from the Server.
// If the Server rejects the CONNECT, it MUST NOT process any data sent by the Client after the CONNECT Packet
//
// Non normative comment
// Clients typically wait for a CONNACK Packet, However,
// if the Client exploits its freedom to send Control Packets before it receives a CONNACK,
// it might simplify the Client implementation as it does not have to police the connected state.
// The Client accepts that any data that it sends before it receives a CONNACK packet from the Server
// will not be processed if the Server rejects the connection.
fn send_packet(
  state: ClientState,
  packet: outgoing.Packet,
) -> Result(ClientState, ChannelError) {
  case state.conn_state {
    ConnectingToServer(channel, _) -> {
      // Don't start ping if connection has not yet finished
      case channel.send(packet) {
        Ok(_) -> Ok(state)
        Error(e) -> Error(e)
      }
    }
    Connected(channel, ping, disconnect) -> {
      case channel.send(packet) {
        Ok(_) -> {
          process.cancel_timer(ping)
          let ping = start_ping_timeout(state)
          Ok(
            ClientState(
              ..state,
              conn_state: Connected(channel, ping, disconnect),
            ),
          )
        }
        Error(e) -> Error(e)
      }
    }
    _ ->
      panic as {
        "Not connecting or connected when trying to send packet: "
        <> string.inspect(packet)
      }
  }
}

fn start_ping_timeout(state: ClientState) -> process.Timer {
  process.send_after(state.self, state.config.keep_alive, Ping)
}

fn reserve_packet_id(state: ClientState) -> #(ClientState, Int) {
  let id = state.packet_id
  let state = ClientState(..state, packet_id: id + 1)
  #(state, id)
}
