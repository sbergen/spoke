//// Provides ETS-backed session storage on the Erlang target.

import spoke/core/session_state.{type SessionState, type StorageUpdate}

/// A handle to the ETS table storing the session state
pub type EtsStorage

/// Any error coming from ETS directly, type not specified
pub type EtsError

/// Create a new empty ETS storage
@external(erlang, "spoke_ets_ffi", "new")
pub fn new() -> EtsStorage

/// Loads a session previously stored to a file using `store_to_file`
@external(erlang, "spoke_ets_ffi", "load_from_file")
pub fn load_from_file(filename: String) -> Result(EtsStorage, EtsError)

@external(erlang, "spoke_ets_ffi", "store_to_file")
pub fn store_to_file(
  storage: EtsStorage,
  filename: String,
) -> Result(Nil, EtsError)

/// Reads the currently stored session state.
@external(erlang, "spoke_ets_ffi", "read")
pub fn read(storage: EtsStorage) -> SessionState

/// Deletes the associated ETS table
@external(erlang, "ets", "delete")
pub fn delete(storage: EtsStorage) -> Nil

/// Updates the state of the storage.
pub fn update(storage: EtsStorage, what: StorageUpdate) -> Nil {
  case what {
    session_state.ClearPacketState(id:) -> clear_packet_state(storage, id)
    session_state.ClearSession -> clear(storage)
    session_state.StoreNextPacketId(id:) -> update_next_id(storage, id)
    session_state.UpdatePacketState(id:, state:) -> store(storage, #(id, state))
  }
}

@external(erlang, "ets", "delete_all_objects")
fn clear(storage: EtsStorage) -> Nil

@external(erlang, "ets", "delete")
fn clear_packet_state(storage: EtsStorage, id: Int) -> Nil

@external(erlang, "spoke_ets_ffi", "update_next_id")
fn update_next_id(storage: EtsStorage, id: Int) -> Nil

@external(erlang, "ets", "insert")
fn store(storage: EtsStorage, data: #(Int, s)) -> Nil
