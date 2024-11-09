import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleamqtt.{
  type ConnectError, type ConnectOptions, type SubscribeError,
  type SubscribeRequest, type Subscription, type Update,
}
import gleamqtt/internal/packet
import gleamqtt/internal/packet/incoming.{type SubscribeResult}
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
  let state = new_state(options, connect, updates)
  let assert Ok(client) = actor.start(state, run_client)
  ClientImpl(client)
}

pub fn connect(client: ClientImpl, timeout: Int) -> Result(Bool, ConnectError) {
  process.call(client.subject, Connect(_), timeout)
}

pub fn subscribe(
  client: ClientImpl,
  topics: List(SubscribeRequest),
  timeout: Int,
) -> Result(List(Subscription), SubscribeError) {
  case process.try_call(client.subject, Subscribe(topics, _), timeout) {
    Ok(result) -> Ok(result)
    Error(_) -> Error(gleamqtt.SubscribeError)
  }
}

type ClientState {
  ClientState(
    options: ConnectOptions,
    connect: fn() -> EncodedChannel,
    updates: Subject(Update),
    conn_state: ConnectionState,
    packet_id: Int,
    pending_subs: Dict(Int, PendingSubscription),
  )
}

type ClientMsg {
  Connect(Subject(Result(Bool, ConnectError)))
  Received(ChannelResult(incoming.Packet))
  Subscribe(List(SubscribeRequest), Subject(List(Subscription)))
}

type ConnectionState {
  Disconnected
  ConnectingToServer(EncodedChannel, Subject(Result(Bool, ConnectError)))
  Connected(EncodedChannel)
}

type PendingSubscription {
  PendingSubscription(
    topics: List(SubscribeRequest),
    reply_to: Subject(List(Subscription)),
  )
}

fn new_state(
  options: ConnectOptions,
  connect: fn() -> EncodedChannel,
  updates: Subject(Update),
) -> ClientState {
  ClientState(options, connect, updates, Disconnected, 0, dict.new())
}

fn run_client(
  msg: ClientMsg,
  state: ClientState,
) -> actor.Next(ClientMsg, ClientState) {
  case msg {
    Connect(reply_to) -> handle_connect(state, reply_to)
    Received(r) -> handle_receive(state, r)
    Subscribe(topics, reply_to) -> handle_subscribe(state, topics, reply_to)
  }
}

fn handle_connect(
  state: ClientState,
  reply_to: Subject(Result(Bool, ConnectError)),
) -> actor.Next(ClientMsg, ClientState) {
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

  let new_state =
    ClientState(..state, conn_state: ConnectingToServer(channel, reply_to))
  actor.with_selector(actor.continue(new_state), new_selector)
}

fn handle_receive(
  state: ClientState,
  data: ChannelResult(incoming.Packet),
) -> actor.Next(ClientMsg, ClientState) {
  let assert Ok(packet) = data

  case packet {
    incoming.ConnAck(status) -> handle_connack(state, status)
    incoming.SubAck(id, results) -> handle_suback(state, id, results)
    incoming.Publish(data) -> handle_publish(state, data)
    _ -> todo as "Packet type not handled"
  }
}

fn handle_connack(
  state: ClientState,
  status: Result(Bool, gleamqtt.ConnectError),
) -> actor.Next(ClientMsg, ClientState) {
  let assert ConnectingToServer(connection, reply_to) = state.conn_state
  process.send(reply_to, status)

  case status {
    Ok(_) ->
      actor.continue(ClientState(..state, conn_state: Connected(connection)))
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
        gleamqtt.SuccessfulSubscription(topic.filter, qos)
      incoming.SubscribeFailure -> gleamqtt.FailedSubscription
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

fn handle_publish(
  state: ClientState,
  data: packet.PublishData,
) -> actor.Next(ClientMsg, ClientState) {
  let update = gleamqtt.ReceivedMessage(data.topic, data.payload, data.retain)
  process.send(state.updates, update)
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
    Connected(channel) -> channel
    _ -> todo as "Not fully connected, handle better"
  }
}
