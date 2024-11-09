import gleam/option.{type Option}
import spoke.{type QoS}

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
