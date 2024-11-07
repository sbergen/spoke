pub type EncodeError {
  EncodeNotImplemented
  EmptySubscribeList
}

pub type DecodeError {
  DecodeNotImplemented
  InvalidPacketIdentifier
  DataTooShort
  InvalidConnAckData
  InvalidConnAckReturnCode
  InvalidPingRespData
  InvalidSubAckData
  InvalidUTF8
  InvalidStringLength
  InvalidVarint
}
