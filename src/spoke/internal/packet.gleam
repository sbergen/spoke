//// Data types shared between incoming and outgoing packets
//// and/or server and client packets

import gleam/option.{type Option}

pub type QoS {
  QoS0
  QoS1
  QoS2
}

/// The core data of a message,
/// which is not dependent on the session state.
pub type MessageData {
  MessageData(topic: String, payload: BitArray, qos: QoS, retain: Bool)
}

// MQTT does not allow using only a password
pub type AuthOptions {
  AuthOptions(user_name: String, password: Option(BitArray))
}

pub type ConnectOptions {
  ConnectOptions(
    clean_session: Bool,
    client_id: String,
    keep_alive_seconds: Int,
    auth: Option(AuthOptions),
    will: Option(MessageData),
  )
}

pub type PublishData {
  PublishData(message: MessageData, dup: Bool, packet_id: Option(Int))
}

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}

pub type ConnectError {
  UnacceptableProtocolVersion
  IdentifierRefused
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
}

pub type SubscribeResult =
  Result(QoS, Nil)

/// The bool is "session present"
pub type ConnAckResult =
  Result(Bool, ConnectError)
