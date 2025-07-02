import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/result
import spoke/packet
import spoke/packet/client/incoming

pub type Timestamp =
  Int

pub opaque type Connection {
  Connection(leftover_data: BitArray)
}

pub fn new() -> Connection {
  Connection(<<>>)
}

/// Attempts to decode the first incoming packet.
/// If there is not enough data, will return success with `None`,
/// but if there is a decoding error, will return an error.
pub fn receive_one(
  connection: Connection,
  data: BitArray,
) -> Result(#(Connection, Option(incoming.Packet)), packet.DecodeError) {
  let data = bit_array.append(connection.leftover_data, data)
  use #(packet, data) <- result.try(case incoming.decode_packet(data) {
    Error(packet.DataTooShort) -> Ok(#(None, data))
    Ok(#(packet, data)) -> Ok(#(Some(packet), data))
    Error(e) -> Error(e)
  })

  Ok(#(Connection(data), packet))
}

/// Attempts to decode all available incoming packets.
pub fn receive_all(
  connection: Connection,
  data: BitArray,
) -> Result(#(Connection, List(incoming.Packet)), packet.DecodeError) {
  let data = bit_array.append(connection.leftover_data, data)
  use #(packets, leftover_data) <- result.try(incoming.decode_packets(data))
  Ok(#(Connection(leftover_data), packets))
}
