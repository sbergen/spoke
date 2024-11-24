import gleam/bit_array
import qcheck
import spoke/internal/packet

pub fn connect_data() -> qcheck.Generator(packet.ConnectOptions) {
  qcheck.return({
    use clean_session <- qcheck.parameter
    use client_id <- qcheck.parameter
    use keep_alive_seconds <- qcheck.parameter
    use auth <- qcheck.parameter
    use will <- qcheck.parameter
    packet.ConnectOptions(
      clean_session,
      client_id,
      keep_alive_seconds,
      auth,
      will,
    )
  })
  |> qcheck.apply(qcheck.bool())
  |> qcheck.apply(qcheck.string_non_empty())
  |> qcheck.apply(mqtt_int())
  |> qcheck.apply(qcheck.option(auth_options()))
  |> qcheck.apply(qcheck.option(message_data()))
}

pub fn auth_options() -> qcheck.Generator(packet.AuthOptions) {
  qcheck.return({
    use username <- qcheck.parameter
    use password <- qcheck.parameter
    packet.AuthOptions(username, password)
  })
  |> qcheck.apply(qcheck.string())
  |> qcheck.apply(qcheck.option(bit_array()))
}

pub fn message_data() -> qcheck.Generator(packet.MessageData) {
  qcheck.return({
    use topic <- qcheck.parameter
    use payload <- qcheck.parameter
    use qos <- qcheck.parameter
    use retain <- qcheck.parameter
    packet.MessageData(topic, payload, qos, retain)
  })
  |> qcheck.apply(qcheck.string_non_empty())
  |> qcheck.apply(bit_array())
  |> qcheck.apply(qos())
  |> qcheck.apply(qcheck.bool())
}

pub fn qos() -> qcheck.Generator(packet.QoS) {
  use i <- qcheck.map(qcheck.int_uniform_inclusive(0, 2))
  case i {
    0 -> packet.QoS0
    1 -> packet.QoS1
    2 -> packet.QoS2
    _ -> panic as "qcheck returned invalid value!"
  }
}

pub fn bit_array() -> qcheck.Generator(BitArray) {
  use str <- qcheck.map(qcheck.string())
  bit_array.from_string(str)
}

fn mqtt_int() -> qcheck.Generator(Int) {
  qcheck.int_uniform_inclusive(0, 65_535)
}
