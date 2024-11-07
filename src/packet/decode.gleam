import gleam/bit_array
import gleam/result

pub fn string(bits: BitArray) -> Result(#(String, BitArray), String) {
  case bits {
    <<len:big-size(16), bytes:bytes-size(len), rest:bits>> -> {
      use str <- result.try(
        bit_array.to_string(bytes)
        |> result.map_error(fn(_) { "Invalid UTF-8 in string" }),
      )
      Ok(#(str, rest))
    }
    _ -> Error("Invalid string length")
  }
}
