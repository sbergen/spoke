pub type QoS {
  QoS0
  QoS1
  QoS2
}

pub type SubAckReturnCode {
  SubscribeSuccess(qos: QoS)
  SubscribeFailure
}

pub type SubscribeTopic {
  SubscribeTopic(filter: String, qos: QoS)
}
