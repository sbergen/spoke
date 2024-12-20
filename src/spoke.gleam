import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import spoke/internal/connection.{type Connection}
import spoke/internal/packet.{type SubscribeResult}
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/transport.{type ByteChannel, type ChannelResult}
import spoke/internal/transport/tcp

pub opaque type Client {
  Client(subject: Subject(Message), config: Config)
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
  Connected(session_present: Bool)
  ConnectionFailed(ConnectError)
  DisconnectedUnexpectedly(reason: String)
  DisconnectedExpectedly
}

pub type PublishData {
  PublishData(topic: String, payload: BitArray, qos: QoS, retain: Bool)
}

pub type OperationError {
  NotConnected
  OperationTimedOut
  ProtocolViolation
  KilledDuringOperation
}

pub type Subscription {
  SuccessfulSubscription(topic_filter: String, qos: QoS)
  FailedSubscription
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

/// Error happened during establishing a connection
pub type ConnectionEstablishError {
  /// A disconnect was requested while connecting
  DisconnectRequested
  /// The MQTT process was killed during a connect call
  KilledDuringConnect
  /// Starting the connection process failed
  FailedToStartConnection(String)
  /// A connect is already established, or being established
  AlreadyConnected
}

/// Error code from the server -
/// we got a response, but 
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
/// The connection state will be published as an update.
/// Note that MQTT allows sending data to the transport channel
/// already before receiving a connection acknowledgement.
/// If establishing a connection or sending the connect packet
/// fails, this will return an error.
pub fn connect(client: Client) -> Result(Nil, ConnectionEstablishError) {
  process.try_call(client.subject, Connect, client.config.server_timeout)
  |> result.map_error(fn(e) {
    case e {
      process.CallTimeout -> FailedToStartConnection("Timed out")
      process.CalleeDown(_) -> KilledDuringConnect
    }
  })
  |> result.flatten
}

pub fn disconnect(client: Client) {
  process.send(client.subject, Disconnect)
}

/// Connects to the MQTT server.
/// Will disconnect if the connect times out,
/// and send the `Disconnect` update.
/// Note that in case of a timeout,
/// the message might still have been already published.
pub fn publish(client: Client, data: PublishData) -> Result(Nil, OperationError) {
  call_or_disconnect(client, Publish(data, _))
}

pub fn subscribe(
  client: Client,
  topics: List(SubscribeRequest),
) -> Result(List(Subscription), OperationError) {
  call_or_disconnect(client, Subscribe(topics, _))
}

pub fn unsubscribe(
  client: Client,
  topics: List(String),
) -> Result(Nil, OperationError) {
  call_or_disconnect(client, Unsubscribe(topics, _))
}

fn call_or_disconnect(
  client: Client,
  make_request: fn(Subject(Result(result, OperationError))) -> Message,
) {
  process.try_call(client.subject, make_request, client.config.server_timeout)
  |> result.map_error(fn(e) {
    case e {
      process.CallTimeout -> {
        process.send(
          client.subject,
          DropConnectionAndNotifyClient("Operation timed out"),
        )
        OperationTimedOut
      }
      process.CalleeDown(_) -> KilledDuringOperation
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
  Client(client, config)
}

fn create_channel(options: TransportOptions) -> ChannelResult(ByteChannel) {
  case options {
    TcpOptions(host, port, connect_timeout) ->
      tcp.connect(host, port, connect_timeout)
  }
}

type Config {
  Config(
    client_id: String,
    keep_alive: Int,
    server_timeout: Int,
    connect: fn() -> ChannelResult(ByteChannel),
  )
}

type State {
  State(
    self: Subject(Message),
    config: Config,
    updates: Subject(Update),
    connection: Option(Connection),
    packet_id: Int,
    pending_subs: Dict(Int, PendingSubscription),
    pending_unsubs: Dict(Int, Subject(OperationResult(Nil))),
  )
}

type OperationResult(a) =
  Result(a, OperationError)

type Message {
  Connect(Subject(Result(Nil, ConnectionEstablishError)))
  Publish(PublishData, Subject(OperationResult(Nil)))
  Subscribe(
    List(SubscribeRequest),
    Subject(OperationResult(List(Subscription))),
  )
  Unsubscribe(List(String), Subject(OperationResult(Nil)))
  ProcessReceived(incoming.Packet)
  ConnectionDropped(connection.Disconnect)
  Disconnect
  DropConnectionAndNotifyClient(String)
}

type PendingSubscription {
  PendingSubscription(
    topics: List(SubscribeRequest),
    reply_to: Subject(OperationResult(List(Subscription))),
  )
}

fn init(
  config: Config,
  updates: Subject(Update),
) -> actor.InitResult(State, Message) {
  let self = process.new_subject()

  let state = State(self, config, updates, None, 1, dict.new(), dict.new())

  let selector =
    process.new_selector()
    |> process.selecting(self, function.identity)

  actor.Ready(state, selector)
}

fn run_client(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Connect(reply_to) -> handle_connect(state, reply_to)
    ProcessReceived(packet) -> process_packet(state, packet)
    Publish(data, reply_to) -> handle_outgoing_publish(state, data, reply_to)
    Subscribe(topics, reply_to) -> handle_subscribe(state, topics, reply_to)
    Unsubscribe(topics, reply_to) -> handle_unsubscribe(state, topics, reply_to)
    ConnectionDropped(reason) -> handle_connection_drop(state, reason)
    Disconnect -> handle_disconnect(state)
    DropConnectionAndNotifyClient(reason) ->
      drop_connection_and_notify(state, Some(reason))
  }
}

fn handle_connection_drop(
  state: State,
  reason: connection.Disconnect,
) -> actor.Next(Message, State) {
  let disconnect = case reason {
    connection.AbnormalDisconnect(reason) -> {
      process.send(state.updates, DisconnectedUnexpectedly(reason))
      True
    }
    connection.GracefulDisconnect -> {
      process.send(state.updates, DisconnectedExpectedly)
      True
    }
  }

  case disconnect {
    True -> actor.continue(State(..state, connection: None))
    False -> actor.continue(state)
  }
}

fn handle_connect(
  state: State,
  reply_to: Subject(Result(Nil, ConnectionEstablishError)),
) -> actor.Next(Message, State) {
  case state.connection {
    Some(_) -> {
      process.send(reply_to, Error(AlreadyConnected))
      actor.continue(state)
    }
    None -> do_connect(state, reply_to)
  }
}

fn do_connect(
  state: State,
  reply_to: Subject(Result(Nil, ConnectionEstablishError)),
) -> actor.Next(Message, State) {
  let config = state.config
  let conn =
    connection.connect(
      config.connect,
      config.client_id,
      config.keep_alive,
      config.server_timeout,
    )

  let result =
    conn
    |> result.map(fn(_) { Nil })
    |> result.map_error(FailedToStartConnection)
  process.send(reply_to, result)

  case conn {
    Ok(conn) -> {
      let selector =
        connection.updates(conn)
        |> process.map_selector(fn(update) {
          case update {
            connection.ReceivedPacket(packet) -> ProcessReceived(packet)
            connection.Disconnected(reason) -> ConnectionDropped(reason)
          }
        })
        |> process.selecting(state.self, function.identity)

      let next = actor.continue(State(..state, connection: Some(conn)))
      actor.with_selector(next, selector)
    }
    Error(_) -> {
      actor.continue(State(..state, connection: None))
    }
  }
}

fn handle_outgoing_publish(
  state: State,
  data: PublishData,
  reply_to: Subject(Result(Nil, OperationError)),
) -> actor.Next(Message, State) {
  // TODO: When should we reply with QoS0?
  // Does it even matter?

  case state.connection {
    Some(connection) -> {
      let message =
        packet.MessageData(
          topic: data.topic,
          payload: data.payload,
          retain: data.retain,
        )
      // TODO: QoS > 0
      let packet = outgoing.Publish(packet.PublishDataQoS0(message))
      connection.send(connection, packet)
      process.send(reply_to, Ok(Nil))
    }
    None -> {
      process.send(reply_to, Error(NotConnected))
    }
  }

  actor.continue(state)
}

fn process_packet(
  state: State,
  packet: incoming.Packet,
) -> actor.Next(Message, State) {
  case packet {
    incoming.ConnAck(result) -> handle_connack(state, result)
    incoming.Publish(data) -> handle_incoming_publish(state, data)
    incoming.SubAck(id, results) -> handle_suback(state, id, results)
    incoming.UnsubAck(id) -> handle_unsuback(state, id)
    _ -> panic as { "Packet type not handled: " <> string.inspect(packet) }
  }
}

fn handle_connack(
  state: State,
  result: packet.ConnAckResult,
) -> actor.Next(Message, State) {
  let update = case result {
    Ok(session_present) -> Connected(session_present)
    Error(e) -> ConnectionFailed(from_packet_connect_error(e))
  }
  process.send(state.updates, update)
  actor.continue(state)
}

fn handle_suback(
  state: State,
  id: Int,
  results: List(SubscribeResult),
) -> actor.Next(Message, State) {
  let subs = state.pending_subs

  use pending_sub <- ok_or_drop_connection(state, dict.get(subs, id), fn(_) {
    "Received invalid packet id in subscribe ack"
  })

  use pairs <- ok_or_drop_connection(
    state,
    list.strict_zip(pending_sub.topics, results),
    fn(_) {
      process.send(pending_sub.reply_to, Error(ProtocolViolation))
      "Received invalid number of results in subscribe ack"
    },
  )

  let results = {
    use #(topic, result) <- list.map(pairs)

    result
    |> result.map(fn(qos) {
      SuccessfulSubscription(topic.filter, from_packet_qos(qos))
    })
    |> result.unwrap(FailedSubscription)
  }

  process.send(pending_sub.reply_to, Ok(results))
  actor.continue(State(..state, pending_subs: dict.delete(subs, id)))
}

fn handle_unsuback(state: State, id: Int) -> actor.Next(Message, State) {
  let unsubs = state.pending_unsubs
  use pending_unsub <- ok_or_drop_connection(state, dict.get(unsubs, id), fn(_) {
    "Received invalid packet id in unsubscribe ack"
  })
  process.send(pending_unsub, Ok(Nil))
  actor.continue(State(..state, pending_unsubs: dict.delete(unsubs, id)))
}

fn handle_subscribe(
  state: State,
  topics: List(SubscribeRequest),
  reply_to: Subject(OperationResult(List(Subscription))),
) -> actor.Next(Message, State) {
  let #(state, id) = reserve_packet_id(state)
  let pending_sub = PendingSubscription(topics, reply_to)
  let pending_subs = state.pending_subs |> dict.insert(id, pending_sub)

  let topics = {
    use topic <- list.map(topics)
    packet.SubscribeRequest(topic.filter, to_packet_qos(topic.qos))
  }

  // TODO: handle not connected
  let assert Some(connection) = state.connection
  connection.send(connection, outgoing.Subscribe(id, topics))

  actor.continue(State(..state, pending_subs:))
}

fn handle_unsubscribe(
  state: State,
  topics: List(String),
  reply_to: Subject(OperationResult(Nil)),
) -> actor.Next(Message, State) {
  let #(state, id) = reserve_packet_id(state)
  let pending_unsubs = state.pending_unsubs |> dict.insert(id, reply_to)

  // TODO: handle not connected
  let assert Some(connection) = state.connection
  connection.send(connection, outgoing.Unsubscribe(id, topics))

  actor.continue(State(..state, pending_unsubs:))
}

fn handle_incoming_publish(
  state: State,
  data: packet.PublishData,
) -> actor.Next(Message, State) {
  // TODO QoS > 0
  // We should have different paths in the future,
  // so not making a function to extract the message.
  let msg = case data {
    packet.PublishDataQoS0(msg) -> msg
    packet.PublishDataQoS1(msg, ..) -> msg
    packet.PublishDataQoS2(msg, ..) -> msg
  }
  let update = ReceivedMessage(msg.topic, msg.payload, msg.retain)
  process.send(state.updates, update)
  actor.continue(state)
}

fn handle_disconnect(state: State) -> actor.Next(Message, State) {
  case state.connection {
    Some(connection) -> {
      connection.send(connection, outgoing.Disconnect)
      drop_connection_and_notify(state, None)
    }
    None -> actor.continue(state)
  }
}

fn drop_connection_and_notify(
  state: State,
  error: Option(String),
) -> actor.Next(Message, State) {
  case state.connection {
    Some(connection) -> {
      connection.shutdown(connection)

      let update = case error {
        None -> DisconnectedExpectedly
        Some(reason) -> DisconnectedUnexpectedly(reason)
      }

      process.send(state.updates, update)
      actor.continue(State(..state, connection: None))
    }
    None -> actor.continue(state)
  }
}

fn ok_or_drop_connection(
  state: State,
  result: Result(a, e),
  make_reason: fn(e) -> String,
  continuation: fn(a) -> actor.Next(Message, State),
) -> actor.Next(Message, State) {
  case result {
    Ok(a) -> continuation(a)
    Error(e) -> {
      drop_connection_and_notify(state, Some(make_reason(e)))
    }
  }
}

fn reserve_packet_id(state: State) -> #(State, Int) {
  let id = state.packet_id
  let state = State(..state, packet_id: id + 1)
  #(state, id)
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
