/// Quality of Service levels, as specified in the MQTT specification
pub type QoS {
  QoS0
  QoS1
  QoS2
}

pub type ConnectError {
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}
