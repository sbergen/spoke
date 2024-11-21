//// Data types shared between incoming and outgoing packets
//// and/or server and client packets

import gleam/option.{type Option}

pub type QoS {
  QoS0
  QoS1
  QoS2
}

pub type PublishData {
  PublishData(
    topic: String,
    payload: BitArray,
    dup: Bool,
    qos: QoS,
    retain: Bool,
    packet_id: Option(Int),
  )
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
