import gleam/list
import gleam/set
import spoke/core/ets_storage.{type EtsStorage}
import spoke/core/session_state.{
  ClearPacketState, ClearSession, ReceivedQoS2, StoreNextPacketId, UnackedQoS1,
  UpdatePacketState,
}
import spoke/packet

pub fn next_id_test() {
  let storage = ets_storage.new()
  ets_storage.update(storage, StoreNextPacketId(42))
  let state = ets_storage.read(storage)

  assert state.packet_id == 42
}

pub fn update_packet_state_test() {
  let message = packet.MessageData("topic", <<"payload">>, True)

  let storage = ets_storage.new()
  ets_storage.update(storage, UpdatePacketState(4, UnackedQoS1(message)))
  ets_storage.update(storage, UpdatePacketState(2, ReceivedQoS2))
  let state = ets_storage.read(storage)

  assert set.from_list(state.packet_states)
    == set.from_list([#(4, UnackedQoS1(message)), #(2, ReceivedQoS2)])
}

pub fn clear_packet_state_test() {
  let message = packet.MessageData("topic", <<"payload">>, True)

  let storage = ets_storage.new()
  ets_storage.update(storage, UpdatePacketState(4, UnackedQoS1(message)))
  ets_storage.update(storage, UpdatePacketState(2, ReceivedQoS2))
  ets_storage.update(storage, ClearPacketState(4))
  let state = ets_storage.read(storage)

  assert state.packet_states == [#(2, ReceivedQoS2)]
}

pub fn clear_session_test() {
  let message = packet.MessageData("topic", <<"payload">>, True)

  let storage = ets_storage.new()
  ets_storage.update(storage, StoreNextPacketId(42))
  ets_storage.update(storage, UpdatePacketState(4, UnackedQoS1(message)))
  ets_storage.update(storage, UpdatePacketState(2, ReceivedQoS2))
  ets_storage.update(storage, ClearSession)
  let state = ets_storage.read(storage)

  assert state.packet_states == []
  assert state.packet_id == 1
}

pub fn delete_test() {
  let storage = ets_storage.new()
  ets_storage.delete(storage)
  assert !list.contains(all_ets_tables(), storage)
}

@external(erlang, "ets", "all")
fn all_ets_tables() -> List(EtsStorage)
