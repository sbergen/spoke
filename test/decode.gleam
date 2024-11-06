import gleam/bit_array.{slice}

pub fn string(bits: BitArray) -> String {
  let assert Ok(<<len:big-size(16)>>) = slice(bits, 0, 2)
  let assert Ok(bytes) = slice(bits, 2, len)
  let assert Ok(result) = bit_array.to_string(bytes)
  result
}
