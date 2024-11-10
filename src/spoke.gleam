/// Quality of Service levels, as specified in the MQTT specification
pub type QoS {
  QoS0
  QoS1
  QoS2
}

pub type ConnectOptions {
  ConnectOptions(client_id: String, keep_alive: Int)
}

pub type ConnectError {
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
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

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}
