//// Encoding of fundamental MQTT data types and shared error codes

import gleam/bit_array

pub type EncodeError {
  EncodeNotImplemented
  EmptySubscribeList
}

pub fn string(str: String) -> BitArray {
  let data = bit_array.from_string(str)
  let len = <<bit_array.byte_size(data):big-size(16)>>
  bit_array.concat([len, data])
}

pub fn varint(i: Int) -> BitArray {
  // TODO: Do we care about the max value (4 bytes)?
  <<>> |> build_varint(i)
}

fn build_varint(bits: BitArray, i: Int) -> BitArray {
  case i < 128 {
    True -> <<bits:bits, i:8>>
    False -> {
      let remainder = i % 128
      <<bits:bits, 1:1, remainder:7>> |> build_varint(i / 128)
    }
  }
}
