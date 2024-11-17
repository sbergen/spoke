import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/string
import spoke.{type ConnectError, type QoS, type SubscribeRequest}
import spoke/internal/interval
import spoke/internal/packet
import spoke/internal/packet/incoming.{type SubscribeResult}
import spoke/internal/packet/outgoing
import spoke/internal/transport/channel.{type EncodedChannel}
import spoke/internal/transport/tcp
import spoke/transport.{type ChannelResult, type TransportOptions}

pub opaque type Client {
  Client(subject: Subject(ClientMsg))
}

pub type ConnectOptions {
  ConnectOptions(
    client_id: String,
    /// Keep-alive interval in seconds (MQTT spec doesn't allow more granular control)
    keep_alive: Int,
  )
}

pub type Update {
  ReceivedMessage(topic: String, payload: BitArray, retained: Bool)
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
    connect_opts.keep_alive * 1000,
    fn() { create_channel(transport_opts) },
    interval.start,
    updates,
  )
}

pub fn connect(
  client: Client,
  timeout timeout: Int,
) -> Result(Bool, ConnectError) {
  process.call(client.subject, Connect(_), timeout)
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
// * start_ping: allows simulating time
// * keep_alive: allow sub-second keep-alive for faster tests
@internal
pub fn run(
  client_id: String,
  keep_alive: Int,
  connect: fn() -> EncodedChannel,
  start_ping: fn(interval.Action, Int) -> interval.Reset,
  updates: Subject(Update),
) -> Client {
  let config = Config(client_id, keep_alive, connect, start_ping)
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
    connect: fn() -> EncodedChannel,
    start_ping: fn(interval.Action, Int) -> interval.Reset,
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
}

type ConnectionState {
  Disconnected
  ConnectingToServer(EncodedChannel, Subject(Result(Bool, ConnectError)))
  Connected(EncodedChannel, interval.Reset)
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

  let state = ClientState(self, config, updates, Disconnected, 1, dict.new())

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
    Ping -> handle_ping(state)
  }
}

fn handle_connect(
  state: ClientState,
  reply_to: Subject(Result(Bool, ConnectError)),
) -> actor.Next(ClientMsg, ClientState) {
  let assert Disconnected = state.conn_state
  let channel = state.config.connect()

  let receives = process.new_subject()
  let new_selector =
    process.new_selector()
    |> process.selecting(state.self, function.identity)
    |> process.selecting(receives, Received(_))
  channel.start_receive(receives)

  let config = state.config
  let connect_packet =
    outgoing.Connect(config.client_id, config.keep_alive / 1000)
  let assert Ok(_) = channel.send(connect_packet)

  let new_state =
    ClientState(..state, conn_state: ConnectingToServer(channel, reply_to))
  actor.with_selector(actor.continue(new_state), new_selector)
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
  let result = case get_channel(state).send(packet) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(PublishError(string.inspect(e)))
  }
  process.send(reply_to, result)
  actor.continue(state)
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
  let assert ConnectingToServer(connection, reply_to) = state.conn_state
  process.send(reply_to, status)

  case status {
    Ok(_) -> {
      let pings =
        state.config.start_ping(
          fn() { process.send(state.self, Ping) },
          state.config.keep_alive,
        )
      actor.continue(
        ClientState(..state, conn_state: Connected(connection, pings)),
      )
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
  let pendietsubs = state.pending_subs |> dict.insert(id, pending_sub)

  let assert Ok(_) = get_channel(state).send(outgoing.Subscribe(id, topics))

  actor.continue(ClientState(..state, pending_subs: pendietsubs))
}

fn handle_incoming_publish(
  state: ClientState,
  data: packet.PublishData,
) -> actor.Next(ClientMsg, ClientState) {
  let update = ReceivedMessage(data.topic, data.payload, data.retain)
  process.send(state.updates, update)
  actor.continue(state)
}

fn handle_ping(state: ClientState) -> actor.Next(ClientMsg, ClientState) {
  let assert Ok(_) = get_channel(state).send(outgoing.PingReq)
  // TODO: Disconnect at some point?
  actor.continue(state)
}

fn handle_pingresp(state: ClientState) -> actor.Next(ClientMsg, ClientState) {
  // TODO: Cancel disconnect
  actor.continue(state)
}

fn reserve_packet_id(state: ClientState) -> #(ClientState, Int) {
  let id = state.packet_id
  let state = ClientState(..state, packet_id: id + 1)
  #(state, id)
}

// TODO: This should do some kind of error handling
// From specs, not sure what to do with this yet:
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
fn get_channel(state: ClientState) {
  case state.conn_state {
    Connected(channel, _) -> channel
    _ -> todo as "Not fully connected, handle better"
  }
}
