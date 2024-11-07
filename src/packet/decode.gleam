import gleam/bit_array
import gleam/result
import packet

pub fn string(bits: BitArray) -> Result(#(String, BitArray), packet.DecodeError) {
  case bits {
    <<len:big-size(16), bytes:bytes-size(len), rest:bits>> -> {
      use str <- result.try(
        bit_array.to_string(bytes)
        |> result.map_error(fn(_) { packet.InvalidUTF8 }),
      )
      Ok(#(str, rest))
    }
    _ -> Error(packet.InvalidStringLength)
  }
}

pub fn varint(bytes: BitArray) -> Result(#(Int, BitArray), packet.DecodeError) {
  accumulate_varint(0, 1, bytes)
}

pub fn accumulate_varint(
  value: Int,
  multiplier: Int,
  bytes: BitArray,
) -> Result(#(Int, BitArray), packet.DecodeError) {
  case multiplier, bytes {
    268_435_456, _ -> Error(packet.InvalidVarint)
    _, <<continue:1, next:7, rest:bits>> -> {
      let value = value + multiplier * next
      case continue {
        0 -> Ok(#(value, rest))
        _ -> accumulate_varint(value, 128 * multiplier, rest)
      }
    }
    _, _ -> Error(packet.InvalidVarint)
  }
}
