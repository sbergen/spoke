import decode
import gleam/bit_array.{slice}
import gleeunit/should
import packet

pub fn connect_test() {
  let p = packet.connect()

  let assert Ok(first_byte) = slice(p, 0, 1)
  first_byte |> should.equal(<<0b00010000>>)

  // TODO
  // let assert Ok(remaining_len) = slice(p, 1, 1)

  decode.string(remaining(p, 2)) |> should.equal("MQTT")
}

fn remaining(bits: BitArray, start: Int) -> BitArray {
  let len = bit_array.byte_size(bits)
  let assert Ok(result) = slice(bits, start, len - start)
  result
}
