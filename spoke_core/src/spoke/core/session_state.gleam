//// Persisted MQTT sessions (e.g. across client restarts) need to store their state.
//// This modules contains the types required for the persistence.

import spoke/packet

/// A QoS > 0 packet has multiple states across its lifetime,
/// they are represented by `PacketState`
pub type PacketState {
  /// A QoS 1 message published by the client,
  /// for which we have not received a PUBACK.
  UnackedQoS1(message: packet.MessageData)

  /// A QoS 2 message published by the client,
  /// for which we have not received a PUBREC.
  UnreceivedQoS2(message: packet.MessageData)

  /// A QoS 2 message published by the client,
  /// for which we have received a PUBREC, but not PUBCOMP.
  ReceivedQoS2

  /// A QoS 2 message received by the client,
  /// for which we have not yet received a PUBREL.
  UnreleasedQoS2
}

/// Represents an action to update the persistent session state.
pub type StorageUpdate {
  /// Clear the whole session (all packet ids)
  ClearSession

  // Store the next packet id to use
  StoreNextPacketId(id: Int)

  /// Clear the state of a single packet.
  /// There might be redundant messages of this kind.
  ClearPacketState(id: Int)

  /// Update the state of a single packet (replaces previous state)
  UpdatePacketState(id: Int, state: PacketState)
}

/// The full session state, in a key-value store friendly format.
pub type SessionState {
  SessionState(packet_id: Int, packet_states: List(#(Int, PacketState)))
}
