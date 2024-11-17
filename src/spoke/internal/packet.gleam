//// Data types shared between incoming and outgoing packets

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
