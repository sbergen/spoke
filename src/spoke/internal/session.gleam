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
import spoke/internal/packet
import spoke/internal/packet/client/outgoing

pub opaque type Session {
  Session(packet_id: Int, unacked_qos1: Dict(Int, packet.MessageData))
}

pub type PubAckResult {
  PublishFinished(Session)
  InvalidPubAckId
}

pub fn new() -> Session {
  Session(packet_id: 1, unacked_qos1: dict.new())
}

pub fn pending_publishes(session: Session) -> Int {
  dict.size(session.unacked_qos1)
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

pub fn handle_puback(session: Session, packet_id: Int) -> PubAckResult {
  case dict.has_key(session.unacked_qos1, packet_id) {
    True -> {
      let unacked_qos1 = dict.delete(session.unacked_qos1, packet_id)
      PublishFinished(Session(..session, unacked_qos1:))
    }
    False -> InvalidPubAckId
  }
}

pub fn packets_to_send_after_connect(session: Session) -> List(outgoing.Packet) {
  use id <- list.map(dict.keys(session.unacked_qos1))
  let assert Ok(message) = dict.get(session.unacked_qos1, id)
  outgoing.Publish(packet.PublishDataQoS1(message, dup: True, packet_id: id))
}
