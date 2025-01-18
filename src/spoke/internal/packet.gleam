//// Data types shared between incoming and outgoing packets
//// and/or server and client packets

import gleam/option.{type Option}

pub type QoS {
  QoS0
  QoS1
  QoS2
}

/// The core data of a message,
/// which is not dependent on the session state or QoS.
pub type MessageData {
  MessageData(topic: String, payload: BitArray, retain: Bool)
}

// MQTT does not allow using only a password
pub type AuthOptions {
  AuthOptions(username: String, password: Option(BitArray))
}

pub type ConnectOptions {
  ConnectOptions(
    clean_session: Bool,
    client_id: String,
    keep_alive_seconds: Int,
    auth: Option(AuthOptions),
    will: Option(#(MessageData, QoS)),
  )
}

/// Data for a published message.
/// QoS0 can never have dup of packet id, thus the variants.
/// This is slightly clunky, but safe.
pub type PublishData {
  PublishDataQoS0(MessageData)
  PublishDataQoS1(message: MessageData, dup: Bool, packet_id: Int)
  PublishDataQoS2(message: MessageData, dup: Bool, packet_id: Int)
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
