import gleam/bit_array

pub fn string(bits: BitArray) -> #(String, BitArray) {
  let assert <<len:big-size(16), rest:bits>> = bits
  let assert <<bytes:bytes-size(len), rest:bits>> = rest
  let assert Ok(result) = bit_array.to_string(bytes)
  #(result, rest)
}
