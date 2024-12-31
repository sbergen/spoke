import gleeunit/should
import spoke/internal/session.{type Session}

pub fn packet_id_increment_test() {
  let session = session.new()

  let assert #(session, 1) = session.reserve_packet_id(session)
    as "Packet ids should start at 1"

  let assert #(_, 2) = session.reserve_packet_id(session)
    as "Packet ids should increment when reserved"
}

pub fn packet_id_wrap_test() {
  let session = session.new()
  let max_id = 65_535
  let session = reserve_n_ids(session, max_id - 1)
  let #(session, id) = session.reserve_packet_id(session)

  id |> should.equal(max_id)

  let assert #(session, 1) = session.reserve_packet_id(session)
    as "Packet id should wrap around to 1"

  let assert #(_, 2) = session.reserve_packet_id(session)
    as "Packet id should increment after wrapping also"
}

fn reserve_n_ids(session: Session, num_ids: Int) -> Session {
  case num_ids {
    0 -> session
    _ -> {
      let #(session, _) = session.reserve_packet_id(session)
      reserve_n_ids(session, num_ids - 1)
    }
  }
}