//// The state of the session that persists over connections.
//// 
//// From the specs:
//// The Session state in the Client consists of:
//// * QoS 1 and QoS 2 messages which have been sent to the Server, but have not been completely acknowledged.
//// * QoS 2 messages which have been received from the Server, but have not been completely acknowledged. 
//// 
//// Also, to simplify things, we keep the packet id also.

pub opaque type Session {
  Session(packet_id: Int)
}

pub fn new() -> Session {
  Session(packet_id: 1)
}

pub fn reserve_packet_id(session: Session) -> #(Session, Int) {
  let id = session.packet_id

  let next_id = case id {
    65_535 -> 1
    id -> id + 1
  }

  #(Session(packet_id: next_id), id)
}
