//// Contains all the data types needed to work with spoke MQTT libraries.
//// This makes it possible to write common code for different targets,
//// and reduces code duplication.

import gleam/option.{type Option, None, Some}

/// Authentication details passed to the server when connecting.
/// Remember that these are not encrypted,
/// unless working with an encrypted transport channel.
pub type AuthDetails {
  AuthDetails(username: String, password: Option(BitArray))
}

/// The set of options used to establish a connection to the server.
/// Includes the set of data that should generally not change across
/// multiple connect calls (if they are needed).
pub type ConnectOptions(t) {
  ConnectOptions(
    /// Transport options, specific to runtime.  
    transport_options: t,
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

/// Strongly typed boolean for session presence, for nicer type signatures.
pub type SessionPresence {
  SessionPresent
  SessionNotPresent
}

/// Represents the state of the connection to the server.
pub type ConnectionState {
  /// Connecting to the server failed before we got a response
  /// to the connect packet.
  ConnectFailed(String)

  /// The server was reachable, but rejected our connect packet
  ConnectRejected(ConnectError)

  /// The server has accepted our connect packet
  ConnectAccepted(SessionPresence)

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
  transport_options: t,
  client_id: String,
) -> ConnectOptions(t) {
  ConnectOptions(
    transport_options:,
    client_id:,
    authentication: None,
    keep_alive_seconds: 15,
    server_timeout_ms: 5000,
  )
}

/// Builder function for specifying the keep-alive time in the connect options.
pub fn keep_alive_seconds(
  options: ConnectOptions(t),
  keep_alive_seconds: Int,
) -> ConnectOptions(t) {
  ConnectOptions(..options, keep_alive_seconds:)
}

/// Builder function for specifying the server operation timeout in the connect options.
pub fn server_timeout_ms(
  options: ConnectOptions(t),
  server_timeout_ms: Int,
) -> ConnectOptions(t) {
  ConnectOptions(..options, server_timeout_ms:)
}

/// Builder function for specifying the authentication details to be used when connecting.
pub fn using_auth(
  options: ConnectOptions(t),
  username: String,
  password: Option(BitArray),
) -> ConnectOptions(t) {
  ConnectOptions(
    ..options,
    authentication: Some(AuthDetails(username, password)),
  )
}
