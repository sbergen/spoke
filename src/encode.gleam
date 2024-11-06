import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}

pub fn string(str: String) -> BitArray {
  let data = bit_array.from_string(str)
  let len = <<bit_array.byte_size(data):big-size(16)>>
  bit_array.concat([len, data])
}

pub fn varint(i: Int) -> BitArray {
  // TODO: Do we care about the max value (4 bytes)?
  bytes_builder.new()
  |> build_varint(i)
  |> bytes_builder.to_bit_array()
}

fn build_varint(builder: BytesBuilder, i: Int) -> BytesBuilder {
  case i < 128 {
    True -> bytes_builder.append(builder, <<i:8>>)
    False -> {
      let remainder = i % 128
      bytes_builder.append(builder, <<1:1, remainder:7>>)
      |> build_varint(i / 128)
    }
  }
}
