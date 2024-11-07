pub type QoS {
  QoS0
  QoS1
  QoS2
}

pub type SubscribeTopic {
  SubscribeTopic(filter: String, qos: QoS)
}
