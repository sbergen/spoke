//// The state of the session that persists over connections.
//// 
//// From the specs:
//// The Session state in the Client consists of:
//// * QoS 1 and QoS 2 messages which have been sent to the Server, but have not been completely acknowledged.
//// * QoS 2 messages which have been received from the Server, but have not been completely acknowledged. 
//// 
//// Also, to simplify things, we keep the packet id also.

import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}
import spoke/packet
import spoke/packet/client/outgoing

pub opaque type Session {
  Session(
    clean_session: Bool,
    packet_id: Int,
    /// Published QoS 1 messages waiting for PubAck,
    /// used for re-transmission of Publish.
    unacked_qos1: Dict(Int, packet.MessageData),
    /// Published QoS 2 messages waiting for PubRec,
    /// used for re-transmission of Publish.
    unreceived_qos2: Dict(Int, packet.MessageData),
    /// Published QoS 2 message ids waiting for PubComp,
    /// used for re-transmission of PubRel.
    unreleased_qos2: Set(Int),
    /// Received QoS 2 message ids waiting for PubRel from publisher,
    /// used for de-duplication.
    incomplete_qos2_in: Set(Int),
  )
}

pub type PubAckResult {
  PublishFinished(Session)
  InvalidPubAckId
}

// TODO: Don't use Bool here
pub fn new(clean_session: Bool) -> Session {
  Session(
    clean_session:,
    packet_id: 1,
    unacked_qos1: dict.new(),
    unreceived_qos2: dict.new(),
    unreleased_qos2: set.new(),
    incomplete_qos2_in: set.new(),
  )
}

pub fn is_ephemeral(session: Session) -> Bool {
  session.clean_session
}

pub fn pending_publishes(session: Session) -> Int {
  dict.size(session.unacked_qos1)
  + dict.size(session.unreceived_qos2)
  + set.size(session.unreleased_qos2)
}

pub fn reserve_packet_id(session: Session) -> #(Session, Int) {
  let id = session.packet_id

  let next_id = case id {
    65_535 -> 1
    id -> id + 1
  }

  #(Session(..session, packet_id: next_id), id)
}

pub fn start_qos1_publish(
  session: Session,
  message: packet.MessageData,
) -> #(Session, outgoing.Packet) {
  let #(session, id) = reserve_packet_id(session)
  let unacked_qos1 = dict.insert(session.unacked_qos1, id, message)

  let packet =
    outgoing.Publish(packet.PublishDataQoS1(message, dup: False, packet_id: id))

  #(Session(..session, unacked_qos1:), packet)
}

pub fn start_qos2_publish(
  session: Session,
  message: packet.MessageData,
) -> #(Session, outgoing.Packet) {
  let #(session, id) = reserve_packet_id(session)
  let unreceived_qos2 = dict.insert(session.unreceived_qos2, id, message)

  let packet =
    outgoing.Publish(packet.PublishDataQoS2(message, dup: False, packet_id: id))

  #(Session(..session, unreceived_qos2:), packet)
}

pub fn handle_pubrec(session: Session, id: Int) -> Session {
  let unreceived_qos2 = dict.delete(session.unreceived_qos2, id)
  let unreleased_qos2 = set.insert(session.unreleased_qos2, id)
  Session(..session, unreceived_qos2:, unreleased_qos2:)
}

pub fn handle_pubcomp(session: Session, id: Int) -> Session {
  let unreleased_qos2 = set.delete(session.unreleased_qos2, id)
  Session(..session, unreleased_qos2:)
}

/// Marks a received packet id as unreleased.
/// The second element in the return value indicates whether we should
/// publish the message to the client or not.
pub fn start_qos2_receive(session: Session, packet_id: Int) -> #(Session, Bool) {
  case set.contains(session.incomplete_qos2_in, packet_id) {
    True -> #(session, False)
    False -> {
      let incomplete_qos2_in = set.insert(session.incomplete_qos2_in, packet_id)
      #(Session(..session, incomplete_qos2_in:), True)
    }
  }
}

pub fn handle_puback(session: Session, packet_id: Int) -> PubAckResult {
  case dict.has_key(session.unacked_qos1, packet_id) {
    True -> {
      let unacked_qos1 = dict.delete(session.unacked_qos1, packet_id)
      PublishFinished(Session(..session, unacked_qos1:))
    }
    False -> InvalidPubAckId
  }
}

pub fn handle_pubrel(session: Session, packet_id: Int) -> Session {
  let incomplete_qos2_in = set.delete(session.incomplete_qos2_in, packet_id)
  Session(..session, incomplete_qos2_in:)
}

pub fn packets_to_send_after_connect(session: Session) -> List(outgoing.Packet) {
  let packets = list.new()

  // Add unacked Qos1 messages
  let packets =
    list.fold(dict.keys(session.unacked_qos1), packets, fn(packets, id) {
      let assert Ok(message) = dict.get(session.unacked_qos1, id)
      let packet =
        outgoing.Publish(packet.PublishDataQoS1(
          message,
          dup: True,
          packet_id: id,
        ))
      [packet, ..packets]
    })

  // Add unreceived QoS2 messages
  let packets =
    list.fold(dict.keys(session.unreceived_qos2), packets, fn(packets, id) {
      let assert Ok(message) = dict.get(session.unreceived_qos2, id)
      let packet =
        outgoing.Publish(packet.PublishDataQoS2(
          message,
          dup: True,
          packet_id: id,
        ))
      [packet, ..packets]
    })

  // Add unreleased QoS2 messages
  let packets =
    list.fold(set.to_list(session.unreleased_qos2), packets, fn(packets, id) {
      [outgoing.PubRel(id), ..packets]
    })

  packets
}
