//// Data types shared between incoming and outgoing packets
//// and/or server and client packets.

import gleam/option.{type Option}

/// The MQTT Quality of service level
/// ([MQTT 4.3](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718099))
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

/// Authentication options.
/// MQTT does not allow using only a password
/// ([MQTT 5.4.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718116))
pub type AuthOptions {
  AuthOptions(username: String, password: Option(BitArray))
}

/// The options passed in CONNECT packets
/// ([MQTT 3.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718028))
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
/// QoS0 can never have dup or packet id, thus the variants.
/// This is slightly clunky, but safe.
/// ([MQTT 3.3](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718037))
pub type PublishData {
  PublishDataQoS0(MessageData)
  PublishDataQoS1(message: MessageData, dup: Bool, packet_id: Int)
  PublishDataQoS2(message: MessageData, dup: Bool, packet_id: Int)
}

/// A single entry in the SUBSCRIBE payload
/// ([MQTT 3.8.3](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718066))
pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}

/// The error values of the CONNECT return code
/// ([MQTT 3.2.2.3](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc385349256))
pub type ConnectError {
  /// The Server does not support the level of the MQTT protocol requested by the Client
  UnacceptableProtocolVersion
  /// The Client identifier is correct UTF-8 but not allowed by the Server
  IdentifierRefused
  /// The Network Connection has been made but the MQTT service is unavailable
  ServerUnavailable
  /// The data in the user name or password is malformed
  BadUsernameOrPassword
  // The Client is not authorized to connect
  NotAuthorized
}

/// The SUBACK payload
/// ([MQTT 3.9.3](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc384800444))
pub type SubscribeResult =
  Result(QoS, Nil)

/// Strongly typed boolean for session presence, for nicer type signatures.
/// ([MQTT 3.2.2.2](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc385349255))
pub type SessionPresence {
  SessionPresent
  SessionNotPresent
}

/// The data in a CONNACK packet
/// ([MQTT 3.2](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718033))
pub type ConnAckResult =
  Result(SessionPresence, ConnectError)

/// An error that can be encountered during decoding.
pub type DecodeError {
  /// The packet identifier in the header was not valid.
  InvalidPacketIdentifier(Int)
  /// The data being decoded did not contain the entire packet.
  DataTooShort
  /// The data contained values that are specified as invalid,
  /// e.g. non-zero reserved bits.
  InvalidData
  /// A string in a packet contained data that wasn't valid UTF-8.
  InvalidUTF8
  /// A QoS value wasn't in the valid range.
  InvalidQoS
  /// A variable-length integer was too long.
  VarIntTooLarge
}
