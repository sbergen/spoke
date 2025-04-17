import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Selector, type Subject}
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
import spoke/internal/session.{type Session}
import spoke/internal/transport.{type ByteChannel}

/// A function that connects a transport channel and
/// returns the send, receive, and shutdown functions or an error.
/// NOTE: This only uses standard library and Erlang types,
/// so that implementors do not need to depend on the Spoke package.
pub type TransportChannelConnector =
  fn() ->
    Result(
      #(
        fn(BytesTree) -> Result(Nil, String),
        fn() -> Selector(Result(BitArray, String)),
        fn() -> Nil,
      ),
      String,
    )

/// An opaque handle for the MQTT client.
/// Can live across multiple sessions and connections,
/// or resume sessions that were previously disconnected.
/// Under the hood, the client is an OTP actor.
pub opaque type Client {
  Client(subject: Subject(Message), updates: Subject(Update), config: Config)
}

/// Authentication details passed to the server when connecting.
/// Remember that these are not encrypted,
/// unless working with an encrypted transport channel.
pub type AuthDetails {
  AuthDetails(username: String, password: Option(BitArray))
}

/// The set of options used to establish a connection to the server.
/// Includes the set of data that should generally not change across
/// multiple connect calls (if they are needed).
pub type ConnectOptions {
  ConnectOptions(
    /// Function to establish a transport channel.
    connector: TransportChannelConnector,
    /// The MQTT client ID used when connecting to the server.
    client_id: String,
    /// Optional username and (additionally optional) password
    authentication: Option(AuthDetails),
    /// Keep-alive interval in seconds (MQTT spec doesn't allow more granular control)
    keep_alive_seconds: Int,
    /// "Reasonable amount of time" for the server to respond (including network latency),
    /// as used in the MQTT specification.
    server_timeout_ms: Int,
  )
}

/// Represents a received message or change in the client.
pub type Update {
  /// A published message to a topic this client was subscribed to was received.
  ReceivedMessage(topic: String, payload: BitArray, retained: Bool)
  /// The connection state of this client changed.
  ConnectionStateChanged(ConnectionState)
}

/// Represents the state of the connection to the server.
pub type ConnectionState {
  /// Connecting to the server failed before we got a response
  /// to the connect packet.
  ConnectFailed(String)

  /// The server was reachable, but rejected our connect packet
  ConnectRejected(ConnectError)

  /// The server has accepted our connect packet
  ConnectAccepted(session_present: Bool)

  /// Disconnected as a result of calling `disconnect`
  Disconnected

  /// The connection was dropped for an unexpected reason,
  /// e.g. a transport channel error or protocol violation.
  DisconnectedUnexpectedly(reason: String)
}

/// A convenience record to hold all the data used when publishing messages.
pub type PublishData {
  PublishData(topic: String, payload: BitArray, qos: QoS, retain: Bool)
}

/// Unified error type for operations that are completed in a blocking way.
pub type OperationError {
  /// The client was not connected when it was required.
  NotConnected
  /// The operation did not complete in time.
  OperationTimedOut
  /// We received unexpected data from the server, and will disconnect.
  ProtocolViolation
  /// The client actor was killed while the operation was in progress.
  KilledDuringOperation
}

/// The result of a subscribe operation
pub type Subscription {
  /// The subscribe succeeded with the specified QoS level.
  SuccessfulSubscription(topic_filter: String, qos: QoS)
  /// The server returned a failure for requested subscription.
  FailedSubscription(topic_filter: String)
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

/// Error code from the server -
/// we got a response, but there was an error.
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

/// Utility record for the data required to request a subscription.
pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}

/// Constructs connect options from transport options, the given client id,
/// and default settings for the rest of the options.
pub fn connect_with_id(
  connector: TransportChannelConnector,
  client_id: String,
) -> ConnectOptions {
  ConnectOptions(
    connector:,
    client_id:,
    authentication: None,
    keep_alive_seconds: 15,
    server_timeout_ms: 5000,
  )
}

/// Builder function for specifying the keep-alive time in the connect options.
pub fn keep_alive_seconds(
  options: ConnectOptions,
  keep_alive_seconds: Int,
) -> ConnectOptions {
  ConnectOptions(..options, keep_alive_seconds:)
}

/// Builder function for specifying the server operation timeout in the connect options.
pub fn server_timeout_ms(
  options: ConnectOptions,
  server_timeout_ms: Int,
) -> ConnectOptions {
  ConnectOptions(..options, server_timeout_ms:)
}

/// Builder function for specifying the authentication details to be used when connecting.
pub fn using_auth(
  options: ConnectOptions,
  username: String,
  password: Option(BitArray),
) -> ConnectOptions {
  ConnectOptions(
    ..options,
    authentication: Some(AuthDetails(username, password)),
  )
}

/// Starts a new MQTT session with the given options.
/// Does not connect to the server, until `connect` is called.
pub fn start_session(connect_options: ConnectOptions) -> Client {
  start_session_with_ms_keep_alive(
    session.new(False),
    connect_options.client_id,
    connect_options.authentication,
    connect_options.keep_alive_seconds * 1000,
    connect_options.server_timeout_ms,
    connect_options.connector,
  )
}

/// Restores an MQTT session from a previously stored state,
/// as returned by `disconnect`.
/// Will return an error if the session state can not be restored
/// from the provided string.
/// Does not connect to the server, until `connect` is called.
pub fn restore_session(
  connect_options: ConnectOptions,
  state: String,
) -> Result(Client, String) {
  session.from_json(state)
  |> result.map_error(string.inspect)
  |> result.map(start_session_with_ms_keep_alive(
    _,
    connect_options.client_id,
    connect_options.authentication,
    connect_options.keep_alive_seconds * 1000,
    connect_options.server_timeout_ms,
    connect_options.connector,
  ))
}

/// Returns a `Subject` for receiving client updates
/// (received messages and connection state changes).
/// NOTE: This function is provided for convenience
/// as receiving updates only works from the process that created the client!
/// Future versions of spoke might support receiving updates in multiple processes. 
pub fn updates(client: Client) -> Subject(Update) {
  client.updates
}

/// Starts connecting to the MQTT server.
/// The connection state will be published as an update.
/// If a connection is already established or being established,
/// this will be a no-op.
/// Note that switching between `clean_session` values
/// while already connecting is currently not well handled.
pub fn connect(client: Client, clean_session: Bool) -> Nil {
  process.send(client.subject, Connect(clean_session, None))
}

/// Same as `connect`, but specifies a will message for this connection.
pub fn connect_with_will(
  client: Client,
  clean_session: Bool,
  will: PublishData,
) -> Nil {
  process.send(client.subject, Connect(clean_session, Some(will)))
}

/// Disconnects from the MQTT server.
/// The connection state change will also be published as an update.
/// If a connection is not established or being established,
/// this will be a no-op.
/// Returns the serialized session state to be potentially restored later.
pub fn disconnect(client: Client) -> String {
  process.call(client.subject, Disconnect, client.config.server_timeout)
}

/// Connects to the MQTT server.
/// Will disconnect if the connect times out,
/// and send the `Disconnect` update.
/// Note that in case of a timeout,
/// the message might still have been already published.
pub fn publish(client: Client, data: PublishData) -> Nil {
  process.send(client.subject, Publish(data))
}

/// Subscribes to the given topics.
/// Will block until we get a response from the server,
/// returning the result of the operation.
pub fn subscribe(
  client: Client,
  topics: List(SubscribeRequest),
) -> Result(List(Subscription), OperationError) {
  process.call(
    client.subject,
    Subscribe(topics, _),
    client.config.server_timeout * 2,
  )
}

/// Unsubscribes from the given topics.
/// Will block until we get a response from the server,
/// returning the result of the operation.
pub fn unsubscribe(
  client: Client,
  topics: List(String),
) -> Result(Nil, OperationError) {
  process.call(
    client.subject,
    Unsubscribe(topics, _),
    client.config.server_timeout * 2,
  )
}

/// Returns the number of QoS > 0 publishes that haven't yet been completely published.
/// Also see `wait_for_publishes_to_finish`.
pub fn pending_publishes(client: Client) -> Int {
  process.call(
    client.subject,
    GetPendingPublishes,
    client.config.server_timeout,
  )
}

/// Wait for all pending QoS > 0 publishes to complete.
/// Returns an error if the operation times out,
/// or client is killed while waiting.
pub fn wait_for_publishes_to_finish(
  client: Client,
  timeout: Int,
) -> Result(Nil, Nil) {
  process.try_call(client.subject, WaitForPublishesToFinish, timeout)
  |> result.replace_error(Nil)
}

/// Allows specifying less than 1 second keep-alive for testing.
@internal
pub fn start_session_with_ms_keep_alive(
  session: Session,
  client_id: String,
  auth: Option(AuthDetails),
  keep_alive_ms: Int,
  server_timeout_ms: Int,
  connector: TransportChannelConnector,
) -> Client {
  let connect = fn() {
    use #(send, receive_next, shutdown) <- result.try(connector())
    Ok(transport.ByteChannel(send, receive_next, shutdown))
  }

  let updates = process.new_subject()
  let config =
    Config(client_id, auth, keep_alive_ms, server_timeout_ms, connect)
  let assert Ok(client) =
    actor.start_spec(actor.Spec(
      fn() { init(config, session, updates) },
      100,
      run_client,
    ))
  Client(client, updates, config)
}

/// For testability, as there should be no other way to crash the actor.
@internal
pub fn unlink_and_crash(client: Client) {
  process.unlink(process.subject_owner(client.subject))
  process.send(client.subject, Crash)
}

type Config {
  Config(
    client_id: String,
    auth: Option(AuthDetails),
    keep_alive: Int,
    server_timeout: Int,
    connect: fn() -> Result(ByteChannel, String),
  )
}

type State {
  State(
    self: Subject(Message),
    config: Config,
    updates: Subject(Update),
    connection: Option(Connection),
    fully_connected: Bool,
    session: Session,
    pending_subs: Dict(Int, PendingSubscription),
    pending_unsubs: Dict(Int, PendingUnsubscribe),
    publish_completion_listeners: List(Subject(Nil)),
  )
}

type OperationResult(a) =
  Result(a, OperationError)

type Message {
  Crash
  Connect(Bool, Option(PublishData))
  Publish(PublishData)
  Subscribe(
    List(SubscribeRequest),
    Subject(OperationResult(List(Subscription))),
  )
  SubscribeTimeout(Int)
  Unsubscribe(List(String), Subject(OperationResult(Nil)))
  UnsubscribeTimeout(Int)
  ProcessReceived(incoming.Packet)
  ConnectionDropped(connection.Disconnect)
  Disconnect(Subject(String))
  DropConnectionAndNotifyClient(String)
  GetPendingPublishes(Subject(Int))
  WaitForPublishesToFinish(Subject(Nil))
}

type PendingSubscription {
  PendingSubscription(
    topics: List(SubscribeRequest),
    reply_to: Subject(OperationResult(List(Subscription))),
    timeout: process.Timer,
  )
}

type PendingUnsubscribe {
  PendingUnsubscribe(
    reply_to: Subject(OperationResult(Nil)),
    timeout: process.Timer,
  )
}

fn init(
  config: Config,
  session: Session,
  updates: Subject(Update),
) -> actor.InitResult(State, Message) {
  let self = process.new_subject()

  let state =
    State(
      self:,
      config:,
      updates:,
      connection: None,
      fully_connected: False,
      session:,
      pending_subs: dict.new(),
      pending_unsubs: dict.new(),
      publish_completion_listeners: [],
    )

  let selector =
    process.new_selector()
    |> process.selecting(self, function.identity)

  actor.Ready(state, selector)
}

fn run_client(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Crash -> panic as "Requested actor to crash"
    Connect(clean_session, will) -> handle_connect(state, clean_session, will)
    ProcessReceived(packet) -> process_packet(state, packet)
    Publish(data) -> handle_outgoing_publish(state, data)
    Subscribe(topics, reply_to) -> handle_subscribe(state, topics, reply_to)
    SubscribeTimeout(id) -> handle_subscribe_timeout(state, id)
    Unsubscribe(topics, reply_to) -> handle_unsubscribe(state, topics, reply_to)
    UnsubscribeTimeout(id) -> handle_unsubscribe_timeout(state, id)
    ConnectionDropped(reason) -> handle_connection_drop(state, reason)
    Disconnect(reply_to) -> handle_disconnect(state, reply_to)
    DropConnectionAndNotifyClient(reason) ->
      drop_connection_and_notify(state, Some(reason))
    GetPendingPublishes(reply_to) -> get_pending_publishes(state, reply_to)
    WaitForPublishesToFinish(reply_to) ->
      handle_wait_for_publishes_to_finish(state, reply_to)
  }
}

fn get_pending_publishes(
  state: State,
  reply_to: Subject(Int),
) -> actor.Next(Message, State) {
  let pending_pubs = session.pending_publishes(state.session)
  process.send(reply_to, pending_pubs)
  actor.continue(state)
}

fn handle_wait_for_publishes_to_finish(state: State, reply_to: Subject(Nil)) {
  let publish_completion_listeners = [
    reply_to,
    ..state.publish_completion_listeners
  ]
  actor.continue(State(..state, publish_completion_listeners:))
}

fn handle_connection_drop(
  state: State,
  reason: connection.Disconnect,
) -> actor.Next(Message, State) {
  let connecting = !state.fully_connected
  let change = case reason {
    connection.AbnormalDisconnect(reason) if connecting ->
      Some(ConnectFailed(reason))

    // This is already handled by the connack status
    connection.GracefulDisconnect if connecting -> None

    connection.AbnormalDisconnect(reason) ->
      Some(DisconnectedUnexpectedly(reason))

    connection.GracefulDisconnect -> Some(Disconnected)
  }

  case change {
    Some(change) -> process.send(state.updates, ConnectionStateChanged(change))
    None -> Nil
  }

  actor.continue(State(..state, connection: None, fully_connected: False))
}

fn handle_connect(
  state: State,
  clean_session: Bool,
  will: Option(PublishData),
) -> actor.Next(Message, State) {
  use <- bool.guard(
    when: option.is_some(state.connection),
    return: actor.continue(state),
  )

  let auth =
    option.map(state.config.auth, fn(auth) {
      packet.AuthOptions(auth.username, auth.password)
    })

  let will =
    option.map(will, fn(will) {
      let data = packet.MessageData(will.topic, will.payload, will.retain)
      #(data, to_packet_qos(will.qos))
    })

  let config = state.config
  let conn =
    connection.connect(
      config.connect,
      config.client_id,
      clean_session,
      config.keep_alive,
      config.server_timeout,
      auth,
      will,
    )

  // [MQTT-3.1.2-6]
  // If CleanSession is set to 1,
  // the Client and Server MUST discard any previous Session and start a new one.
  // This Session lasts as long as the Network Connection.
  // State data associated with this Session MUST NOT be reused in any subsequent Session.
  let session = case clean_session || session.is_ephemeral(state.session) {
    True -> session.new(clean_session)
    False -> state.session
  }

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

      let state = State(..state, connection: Some(conn), session:)

      session.packets_to_send_after_connect(state.session)
      |> list.each(connection.send(conn, _))

      actor.with_selector(actor.continue(state), selector)
    }
    Error(_) -> {
      actor.continue(State(..state, connection: None))
    }
  }
}

fn handle_outgoing_publish(
  state: State,
  data: PublishData,
) -> actor.Next(Message, State) {
  let message =
    packet.MessageData(
      topic: data.topic,
      payload: data.payload,
      retain: data.retain,
    )

  let #(session, packet) = case data.qos {
    AtMostOnce -> #(
      state.session,
      outgoing.Publish(packet.PublishDataQoS0(message)),
    )
    AtLeastOnce -> session.start_qos1_publish(state.session, message)
    ExactlyOnce -> session.start_qos2_publish(state.session, message)
  }
  let state = State(..state, session:)

  use connection <- guard_connected(state, fn() {
    // QoS 0 packets are just dropped, QoS > 0 have been saved in the session
    actor.continue(state)
  })

  connection.send(connection, packet)
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
    incoming.PubAck(id) -> handle_puback(state, id)
    incoming.PubRel(id) -> handle_pubrel(state, id)
    incoming.PubRec(id) -> handle_pubrec(state, id)
    incoming.PubComp(id) -> handle_pubcomp(state, id)

    // Handled by the connection
    incoming.PingResp -> actor.continue(state)
  }
}

fn handle_connack(
  state: State,
  result: packet.ConnAckResult,
) -> actor.Next(Message, State) {
  let update = case result {
    Ok(session_present) -> ConnectAccepted(session_present)
    Error(e) -> ConnectRejected(from_packet_connect_error(e))
  }
  process.send(state.updates, ConnectionStateChanged(update))
  actor.continue(State(..state, fully_connected: result.is_ok(result)))
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

  process.cancel_timer(pending_sub.timeout)

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
    |> result.unwrap(FailedSubscription(topic.filter))
  }

  process.send(pending_sub.reply_to, Ok(results))
  actor.continue(State(..state, pending_subs: dict.delete(subs, id)))
}

fn handle_unsuback(state: State, id: Int) -> actor.Next(Message, State) {
  let unsubs = state.pending_unsubs
  use pending_unsub <- ok_or_drop_connection(state, dict.get(unsubs, id), fn(_) {
    "Received invalid packet id in unsubscribe ack"
  })
  process.cancel_timer(pending_unsub.timeout)
  process.send(pending_unsub.reply_to, Ok(Nil))
  actor.continue(State(..state, pending_unsubs: dict.delete(unsubs, id)))
}

fn handle_puback(state: State, id: Int) -> actor.Next(Message, State) {
  case session.handle_puback(state.session, id) {
    session.InvalidPubAckId ->
      drop_connection_and_notify(
        state,
        Some("Received invalid packet id in publish ack"),
      )

    session.PublishFinished(session) -> {
      State(..state, session:)
      |> notify_if_publishes_finished
      |> actor.continue
    }
  }
}

fn handle_pubrel(state: State, id: Int) -> actor.Next(Message, State) {
  use connection <- guard_connected(state, fn() { actor.continue(state) })

  // Whether or not we already sent PubComp, we always do it when receiving PubRel.
  // This is in case we lose the connection after PubRec
  connection.send(connection, outgoing.PubComp(id))
  let session = session.handle_pubrel(state.session, id)
  actor.continue(State(..state, session:))
}

fn handle_pubrec(state: State, id: Int) -> actor.Next(Message, State) {
  use connection <- guard_connected(state, fn() { actor.continue(state) })

  let session = session.handle_pubrec(state.session, id)
  connection.send(connection, outgoing.PubRel(id))
  actor.continue(State(..state, session:))
}

fn handle_pubcomp(state: State, id: Int) -> actor.Next(Message, State) {
  let session = session.handle_pubcomp(state.session, id)
  let state =
    State(..state, session:)
    |> notify_if_publishes_finished

  actor.continue(state)
}

fn handle_subscribe(
  state: State,
  topics: List(SubscribeRequest),
  reply_to: Subject(OperationResult(List(Subscription))),
) -> actor.Next(Message, State) {
  use connection <- guard_connected(state, fn() {
    process.send(reply_to, Error(NotConnected))
    actor.continue(state)
  })

  let #(session, id) = session.reserve_packet_id(state.session)
  let timeout =
    process.send_after(
      state.self,
      state.config.server_timeout,
      SubscribeTimeout(id),
    )
  let pending_sub = PendingSubscription(topics, reply_to, timeout)
  let pending_subs = state.pending_subs |> dict.insert(id, pending_sub)

  let topics = {
    use topic <- list.map(topics)
    packet.SubscribeRequest(topic.filter, to_packet_qos(topic.qos))
  }
  connection.send(connection, outgoing.Subscribe(id, topics))

  actor.continue(State(..state, session:, pending_subs:))
}

fn handle_subscribe_timeout(state: State, id: Int) -> actor.Next(Message, State) {
  let pending_subs = state.pending_subs

  case dict.get(pending_subs, id) {
    // If the key was not found, it means that the suback
    // and timeout were in the mailbox at the same time.
    Error(_) -> actor.continue(state)
    Ok(PendingSubscription(_, reply_to, _)) -> {
      process.send(reply_to, Error(OperationTimedOut))
      let pending_subs = dict.delete(pending_subs, id)
      drop_connection_and_notify(
        State(..state, pending_subs:),
        Some("Subscribe timed out"),
      )
    }
  }
}

fn handle_unsubscribe(
  state: State,
  topics: List(String),
  reply_to: Subject(OperationResult(Nil)),
) -> actor.Next(Message, State) {
  use connection <- guard_connected(state, fn() {
    process.send(reply_to, Error(NotConnected))
    actor.continue(state)
  })

  let #(session, id) = session.reserve_packet_id(state.session)
  let timeout =
    process.send_after(
      state.self,
      state.config.server_timeout,
      UnsubscribeTimeout(id),
    )
  let pending_unsubs =
    state.pending_unsubs
    |> dict.insert(id, PendingUnsubscribe(reply_to, timeout))

  connection.send(connection, outgoing.Unsubscribe(id, topics))

  actor.continue(State(..state, session:, pending_unsubs:))
}

fn handle_unsubscribe_timeout(
  state: State,
  id: Int,
) -> actor.Next(Message, State) {
  let pending_unsubs = state.pending_unsubs

  case dict.get(pending_unsubs, id) {
    // If the key was not found, it means that the unsuback
    // and timeout were in the mailbox at the same time.
    Error(_) -> actor.continue(state)
    Ok(PendingUnsubscribe(reply_to, _)) -> {
      process.send(reply_to, Error(OperationTimedOut))
      let pending_unsubs = dict.delete(pending_unsubs, id)
      drop_connection_and_notify(
        State(..state, pending_unsubs:),
        Some("Unsubscribe timed out"),
      )
    }
  }
}

fn handle_incoming_publish(
  state: State,
  data: packet.PublishData,
) -> actor.Next(Message, State) {
  let #(msg, session, packet) = case data {
    packet.PublishDataQoS0(msg) -> #(Some(msg), state.session, None)

    // dup is essentially useless,
    // as we don't know if we have already received this or not.
    packet.PublishDataQoS1(msg, _dup, id) -> #(
      Some(msg),
      state.session,
      Some(outgoing.PubAck(id)),
    )

    packet.PublishDataQoS2(msg, _dup, id) -> {
      let #(session, publish_result) =
        session.start_qos2_receive(state.session, id)
      let msg = case publish_result {
        True -> Some(msg)
        False -> None
      }
      #(msg, session, Some(outgoing.PubRec(id)))
    }
  }

  case packet, state.connection {
    Some(packet), Some(connection) -> connection.send(connection, packet)
    _, _ -> Nil
  }

  case msg {
    Some(msg) -> {
      let update = ReceivedMessage(msg.topic, msg.payload, msg.retain)
      process.send(state.updates, update)
    }
    None -> Nil
  }

  actor.continue(State(..state, session:))
}

fn handle_disconnect(
  state: State,
  reply_to: Subject(String),
) -> actor.Next(Message, State) {
  let result = case state.connection {
    Some(connection) -> {
      connection.send(connection, outgoing.Disconnect)
      connection.shutdown(connection)
      actor.continue(State(..state, connection: None))
    }
    None -> actor.continue(state)
  }

  process.send(reply_to, session.to_json(state.session))
  result
}

fn notify_if_publishes_finished(state: State) -> State {
  case session.pending_publishes(state.session) {
    0 -> {
      {
        use listener <- list.each(state.publish_completion_listeners)
        process.send(listener, Nil)
      }
      State(..state, publish_completion_listeners: [])
    }
    _ -> state
  }
}

fn guard_connected(
  state: State,
  if_not_connected: fn() -> actor.Next(Message, State),
  if_connected: fn(Connection) -> actor.Next(Message, State),
) -> actor.Next(Message, State) {
  case state.connection {
    None -> if_not_connected()
    Some(connection) -> if_connected(connection)
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
        None -> Disconnected
        Some(reason) -> DisconnectedUnexpectedly(reason)
      }

      process.send(state.updates, ConnectionStateChanged(update))
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
