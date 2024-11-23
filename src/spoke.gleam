import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import spoke/internal/packet.{type SubscribeResult}
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/transport.{type ChannelError, type ChannelResult}
import spoke/internal/transport/channel.{type EncodedChannel}
import spoke/internal/transport/tcp

pub opaque type Client {
  Client(subject: Subject(ClientMsg))
}

pub type TransportOptions {
  TcpOptions(host: String, port: Int, connect_timeout: Int)
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
  PublishTimedOut
  PublishChannelError(String)
  KilledDuringPublish
}

pub type Subscription {
  SuccessfulSubscription(topic_filter: String, qos: QoS)
  FailedSubscription
}

pub type SubscribeError {
  // TODO more details here
  SubscribeError
}

/// Quality of Service levels, as specified in the MQTT specification
pub type QoS {
  /// The message is delivered according to the capabilities of the underlying network.
  /// No response is sent by the receiver and no retry is performed by the sender.
  /// The message arrives at the receiver either once or not at all.
  AtMostOnce

  /// This quality of service ensures that the message arrives at the receiver at least once.
  AtLeastOnce

  /// This is the highest quality of service,
  /// for use when neither loss nor duplication of messages are acceptable.
  /// There is an increased overhead associated with this quality of service.
  ExactlyOnce
}

pub type ConnectError {
  /// The MQTT server doesn't support MQTT 3.1.1
  UnacceptableProtocolVersion
  /// The Client identifier is correct UTF-8 but not allowed by the Server
  IdentifierRefused
  /// The Network Connection has been made but the MQTT service is unavailable
  ServerUnavailable
  /// The data in the user name or password is malformed
  BadUsernameOrPassword
  /// The Client is not authorized to connect
  NotAuthorized
  /// A disconnect was requested while connecting
  DisconnectRequested
  /// The connection timed out
  ConnectTimedOut
  /// The MQTT process was killed during a connect call
  KilledDuringConnect
  /// There was a transport channel error during connecting
  ConnectChannelError(String)
  /// A connect is already established, or being established
  AlreadyConnected
}

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}

/// Starts a new MQTT client with the given options
pub fn start(
  connect_opts: ConnectOptions,
  transport_opts: TransportOptions,
  updates: Subject(Update),
) -> Client {
  start_with_ms_keep_alive(
    connect_opts.client_id,
    connect_opts.keep_alive_seconds * 1000,
    connect_opts.server_timeout_ms,
    transport_opts,
    updates,
  )
}

/// Connects to the MQTT server.
/// Will disconnect if the connect times out,
/// and send the `Disconnect` update.
pub fn connect(
  client: Client,
  timeout timeout: Int,
) -> Result(Bool, ConnectError) {
  call_or_disconnect(
    client,
    Connect(_),
    timeout,
    KilledDuringConnect,
    ConnectTimedOut,
  )
}

pub fn disconnect(client: Client) {
  process.send(client.subject, Disconnect)
}

/// Connects to the MQTT server.
/// Will disconnect if the connect times out,
/// and send the `Disconnect` update.
/// Note that in case of a timeout,
/// the message might still have been already published.
pub fn publish(
  client: Client,
  data: PublishData,
  timeout: Int,
) -> Result(Nil, PublishError) {
  call_or_disconnect(
    client,
    Publish(data, _),
    timeout,
    KilledDuringPublish,
    PublishTimedOut,
  )
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

fn call_or_disconnect(
  client: Client,
  make_request: fn(Subject(Result(result, error))) -> ClientMsg,
  timeout: Int,
  killed_error: error,
  timed_out_error: error,
) {
  process.try_call(client.subject, make_request, timeout)
  |> result.map_error(fn(e) {
    case e {
      process.CallTimeout -> {
        process.send(client.subject, DropConnectionAndNotifyClient)
        timed_out_error
      }
      process.CalleeDown(_) -> killed_error
    }
  })
  |> result.flatten
}

// allows specifying less than 1 second keep-alive for testing
@internal
pub fn start_with_ms_keep_alive(
  client_id: String,
  keep_alive_ms: Int,
  server_timeout_ms: Int,
  transport_opts: TransportOptions,
  updates: Subject(Update),
) -> Client {
  let connect = fn() { create_channel(transport_opts) }
  let config = Config(client_id, keep_alive_ms, server_timeout_ms, connect)
  let assert Ok(client) =
    actor.start_spec(actor.Spec(fn() { init(config, updates) }, 100, run_client))
  Client(client)
}

fn create_channel(options: TransportOptions) -> ChannelResult(EncodedChannel) {
  case options {
    TcpOptions(host, port, connect_timeout) ->
      tcp.connect(host, port, connect_timeout)
  }
  |> result.map(channel.as_encoded)
}

type Config {
  Config(
    client_id: String,
    keep_alive: Int,
    server_timeout: Int,
    connect: fn() -> ChannelResult(EncodedChannel),
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
  Received(#(BitArray, ChannelResult(List(incoming.Packet))))
  ProcessReceived(incoming.Packet)
  Ping
  Disconnect
  DropConnectionAndNotifyClient
}

type ConnectionState {
  NotConnected
  ConnectingToServer(
    channel: EncodedChannel,
    reply_to: Subject(Result(Bool, ConnectError)),
  )
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
    Received(#(new_chan_state, packets)) ->
      handle_receive(state, new_chan_state, packets)
    ProcessReceived(packet) -> process_packet(state, packet)
    Publish(data, reply_to) -> handle_outgoing_publish(state, data, reply_to)
    Subscribe(topics, reply_to) -> handle_subscribe(state, topics, reply_to)
    Ping -> send_ping(state)
    Disconnect -> handle_disconnect(state)
    DropConnectionAndNotifyClient -> drop_connection_and_notify(state)
  }
}

fn handle_connect(
  state: ClientState,
  reply_to: Subject(Result(Bool, ConnectError)),
) -> actor.Next(ClientMsg, ClientState) {
  case state.conn_state {
    NotConnected -> do_connect(state, reply_to)
    _ -> {
      process.send(reply_to, Error(AlreadyConnected))
      actor.continue(state)
    }
  }
}

fn do_connect(
  state: ClientState,
  reply_to: Subject(Result(Bool, ConnectError)),
) -> actor.Next(ClientMsg, ClientState) {
  case state.config.connect() {
    Ok(channel) -> {
      let state =
        ClientState(..state, conn_state: ConnectingToServer(channel, reply_to))

      let config = state.config
      let connect_packet =
        outgoing.Connect(config.client_id, config.keep_alive / 1000)
      case send_packet(state, connect_packet) {
        Ok(state) -> {
          let selector = next_selector(channel, <<>>, state.self)
          actor.with_selector(actor.continue(state), selector)
        }
        Error(e) -> {
          process.send(reply_to, Error(ConnectChannelError(string.inspect(e))))
          actor.continue(close_channel(state))
        }
      }
    }
    Error(e) -> {
      // Channel connection failed, no change to state
      process.send(reply_to, Error(ConnectChannelError(string.inspect(e))))
      actor.continue(state)
    }
  }
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
      qos: to_packet_qos(data.qos),
      retain: data.retain,
      packet_id: None,
    ))
  case send_packet(state, packet) {
    Ok(new_state) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }
    Error(e) -> {
      process.send(reply_to, Error(PublishChannelError(string.inspect(e))))
      actor.continue(state)
    }
  }
}

fn handle_receive(
  state: ClientState,
  new_conn_state: BitArray,
  packets: ChannelResult(List(incoming.Packet)),
) -> actor.Next(ClientMsg, ClientState) {
  let state = case packets {
    Ok(packets) -> {
      list.each(packets, fn(packet) {
        process.send(state.self, ProcessReceived(packet))
      })
      state
    }
    Error(e) ->
      case state.conn_state, e {
        // This is expected, nothing to do
        NotConnected, transport.ChannelClosed -> state
        ConnectingToServer(_, reply_to), e -> {
          let reply = Error(ConnectChannelError(string.inspect(e)))
          process.send(reply_to, reply)
          close_channel(state)
        }
        _, _ -> {
          process.send(state.updates, Disconnected)
          close_channel(state)
        }
      }
  }

  // TODO: Pending subscribes aren't handled in the error cases above.
  // I'm wondering if we really need to make it blocking or not?

  use channel <- if_connected(state)
  actor.with_selector(
    actor.continue(state),
    next_selector(channel, new_conn_state, state.self),
  )
}

fn process_packet(
  state: ClientState,
  packet: incoming.Packet,
) -> actor.Next(ClientMsg, ClientState) {
  use _ <- if_connected(state)
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
  status: packet.ConnAckResult,
) -> actor.Next(ClientMsg, ClientState) {
  let assert ConnectingToServer(channel, reply_to) = state.conn_state

  process.send(reply_to, result.map_error(status, from_packet_connect_error))

  case status {
    Ok(_session_present) -> {
      let conn_state = Connected(channel, start_ping_timeout(state), None)
      actor.continue(ClientState(..state, conn_state: conn_state))
    }
    Error(_) -> {
      // If a server sends a CONNACK packet containing a non-zero return code
      // it MUST then close the Network Connection
      // => close channel just in case, but don't send any update on this,
      // as we were never connected.
      actor.continue(close_channel(state))
    }
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

    result
    |> result.map(fn(qos) {
      SuccessfulSubscription(topic.filter, from_packet_qos(qos))
    })
    |> result.unwrap(FailedSubscription)
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

  let topics = {
    use topic <- list.map(topics)
    packet.SubscribeRequest(topic.filter, to_packet_qos(topic.qos))
  }
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
    // There can be some race conditions here, especially with our test values.
    // Just ignore the ping if we are not fully connected.
    NotConnected | ConnectingToServer(_, _) -> actor.continue(state)
    Connected(channel, ping, disconnect) -> {
      // We should not be waiting for a ping
      let assert None = disconnect
      // ..and also no longer scheduling a ping
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
    ConnectingToServer(_, reply_to) -> {
      process.send(reply_to, Error(DisconnectRequested))
    }
    Connected(channel, ..) -> {
      // Do we care about errors here?
      let assert Ok(_) = channel.send(outgoing.Disconnect)
      Nil
    }
    _ -> Nil
  }

  process.send(state.updates, Disconnected)
  drop_connection_and_notify(state)
}

fn drop_connection_and_notify(
  state: ClientState,
) -> actor.Next(ClientMsg, ClientState) {
  process.send(state.updates, Disconnected)
  actor.continue(close_channel(state))
}

/// Closes the channel and cancels any timeouts,
/// does not send anything to client.
/// NOTE: ConnectingToServer responses are NOT completed!
fn close_channel(state: ClientState) -> ClientState {
  case state.conn_state {
    ConnectingToServer(channel, _) -> {
      channel.shutdown()
    }
    Connected(channel, ping, disconnect) -> {
      process.cancel_timer(ping)

      // Play it safe:
      case disconnect {
        Some(disconnect) -> process.cancel_timer(disconnect)
        None -> process.TimerNotFound
      }

      channel.shutdown()
    }
    NotConnected -> Nil
  }

  ClientState(..state, conn_state: NotConnected)
}

fn next_selector(
  channel: EncodedChannel,
  channel_state: BitArray,
  self: Subject(ClientMsg),
) -> process.Selector(ClientMsg) {
  process.map_selector(channel.selecting_next(channel_state), Received(_))
  |> process.selecting(self, function.identity)
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
      use _ <- result.try(channel.send(packet))
      Ok(state)
    }
    Connected(channel, ping, disconnect) -> {
      use _ <- result.try(channel.send(packet))
      process.cancel_timer(ping)
      let ping = start_ping_timeout(state)
      Ok(ClientState(..state, conn_state: Connected(channel, ping, disconnect)))
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

fn if_connected(
  state: ClientState,
  do: fn(channel.EncodedChannel) -> actor.Next(ClientMsg, ClientState),
) -> actor.Next(ClientMsg, ClientState) {
  case state.conn_state {
    NotConnected -> actor.continue(state)
    Connected(channel, _, _) | ConnectingToServer(channel, _) -> do(channel)
  }
}

// The below conversion are _mostly_ required because we can't re-export constructors

fn to_packet_qos(qos: QoS) -> packet.QoS {
  case qos {
    AtMostOnce -> packet.QoS0
    AtLeastOnce -> packet.QoS1
    ExactlyOnce -> packet.QoS2
  }
}

fn from_packet_qos(qos: packet.QoS) -> QoS {
  case qos {
    packet.QoS0 -> AtMostOnce
    packet.QoS1 -> AtLeastOnce
    packet.QoS2 -> ExactlyOnce
  }
}

fn from_packet_connect_error(error: packet.ConnectError) -> ConnectError {
  case error {
    packet.BadUsernameOrPassword -> BadUsernameOrPassword
    packet.IdentifierRefused -> IdentifierRefused
    packet.NotAuthorized -> NotAuthorized
    packet.ServerUnavailable -> ServerUnavailable
    packet.UnacceptableProtocolVersion -> UnacceptableProtocolVersion
  }
}
