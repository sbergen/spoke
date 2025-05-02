import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/packet
import spoke/packet/client/incoming

pub type Timestamp =
  Int

pub opaque type Connection {
  Connection(
    leftover_data: BitArray,
    next_ping: Option(Timestamp),
    keep_alive: Int,
  )
}

pub fn new(time: Timestamp, keep_alive: Int) -> Connection {
  // TODO: set disconnect timeout
  Connection(<<>>, None, keep_alive)
}

pub fn sent_ping(connection: Connection) -> Connection {
  // TODO: set disconnect timeout
  Connection(..connection, next_ping: None)
}

pub fn next_ping(connection: Connection) -> Option(Timestamp) {
  connection.next_ping
}

pub fn receive_one(
  connection: Connection,
  time: Timestamp,
  data: BitArray,
) -> Result(#(Connection, Option(incoming.Packet)), packet.DecodeError) {
  let data = bit_array.append(connection.leftover_data, data)
  use #(packet, data) <- result.try(case incoming.decode_packet(data) {
    Error(packet.DataTooShort) -> Ok(#(None, data))
    Ok(#(packet, data)) -> Ok(#(Some(packet), data))
    Error(e) -> Error(e)
  })

  Ok(#(next(connection, time, data), packet))
}

pub fn receive_all(
  connection: Connection,
  time: Timestamp,
  data: BitArray,
) -> Result(#(Connection, List(incoming.Packet)), packet.DecodeError) {
  let data = bit_array.append(connection.leftover_data, data)
  use #(packets, leftover_data) <- result.try(incoming.decode_all(data))
  Ok(#(next(connection, time, leftover_data), packets))
}

fn next(
  connection: Connection,
  time: Timestamp,
  leftover_data: BitArray,
) -> Connection {
  let next_ping = Some(time + connection.keep_alive)
  Connection(..connection, leftover_data:, next_ping:)
}
