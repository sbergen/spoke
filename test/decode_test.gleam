import decode

pub fn decode_string_invalid_length_test() {
  let assert Error("Invalid string length") = decode.string(<<8:16, 0>>)
}

pub fn decode_string_invalid_data_test() {
  let assert Error("Invalid UTF-8 in string") =
    decode.string(<<2:16, 0xc3, 0x28>>)
}
