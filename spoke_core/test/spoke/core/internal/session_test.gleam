import gleeunit/should
import spoke/core/internal/session.{type Session}
import spoke/packet

pub fn ephemeral_session_serialize_test() {
  session.new(True)
  |> session.to_json
  |> session.from_json
  |> should.equal(Ok(session.new(True)))
}

pub fn invalid_version_fails_deserialization_test() {
  session.from_json("{ \"version\": 42 }")
  |> should.be_error
}

pub fn non_ephemeral_session_persists_state_test() {
  let message_data = packet.MessageData("topic", <<"payload">>, False)

  let session = session.new(False)
  let #(session, _) = session.reserve_packet_id(session)
  let #(session, _) = session.start_qos1_publish(session, message_data)
  let #(session, _) = session.start_qos2_receive(session, 42)
  let #(session, _) = session.start_qos2_publish(session, message_data)
  let session = session.handle_pubrec(session, 43)

  session
  |> session.to_json
  |> session.from_json
  |> should.equal(Ok(session))
}

pub fn packet_id_increment_test() {
  let session = session.new(True)

  let assert #(session, 1) = session.reserve_packet_id(session)
    as "Packet ids should start at 1"

  let assert #(_, 2) = session.reserve_packet_id(session)
    as "Packet ids should increment when reserved"
}

pub fn packet_id_wrap_test() {
  let session = session.new(True)
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
