/// Quality of Service levels, as specified in the MQTT specification
pub type QoS {
  /// The message is delivered according to the capabilities of the underlying network.
  /// No response is sent by the receiver and no retry is performed by the sender.
  /// The message arrives at the receiver either once or not at all.
  QoS0

  /// This quality of service ensures that the message arrives at the receiver at least once.
  QoS1

  /// This is the highest quality of service,
  /// for use when neither loss nor duplication of messages are acceptable.
  /// There is an increased overhead associated with this quality of service.
  QoS2
}

pub type ConnectOptions {
  ConnectOptions(client_id: String, keep_alive: Int)
}

pub type ConnectReturnCode {
  ConnectionAccepted
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub type Update {
  ReceivedMessage(topic: String, payload: BitArray, retained: Bool)
  ConnectFinished(status: ConnectReturnCode, session_present: Bool)
}

pub type Subscription {
  Subscription(topic_filter: String, qos: QoS)
}

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}
