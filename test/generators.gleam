import gleam/bit_array
import gleam/list
import qcheck.{type Generator}
import spoke/internal/packet
import spoke/internal/packet/client/outgoing

pub fn connect_data() -> Generator(packet.ConnectOptions) {
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

pub fn connack_result() -> Generator(packet.ConnAckResult) {
  use success <- qcheck.bind(qcheck.bool())
  case success {
    True -> {
      use session_present <- qcheck.map(qcheck.bool())
      Ok(session_present)
    }
    False -> {
      use error <- qcheck.map(
        from_list([
          packet.UnacceptableProtocolVersion,
          packet.IdentifierRefused,
          packet.ServerUnavailable,
          packet.BadUsernameOrPassword,
          packet.NotAuthorized,
        ]),
      )
      Error(error)
    }
  }
}

pub fn subscribe_request() -> Generator(#(Int, List(packet.SubscribeRequest))) {
  qcheck.return({
    use packet_id <- qcheck.parameter
    use requests <- qcheck.parameter
    #(packet_id, requests)
  })
  |> qcheck.apply(packet_id())
  |> qcheck.apply(qcheck.list_generic(one_subscribe_request(), 1, 5))
}

fn one_subscribe_request() -> Generator(packet.SubscribeRequest) {
  qcheck.return({
    use filter <- qcheck.parameter
    use qos <- qcheck.parameter
    packet.SubscribeRequest(filter, qos)
  })
  |> qcheck.apply(qcheck.string())
  |> qcheck.apply(qos())
}

fn auth_options() -> Generator(packet.AuthOptions) {
  qcheck.return({
    use username <- qcheck.parameter
    use password <- qcheck.parameter
    packet.AuthOptions(username, password)
  })
  |> qcheck.apply(qcheck.string())
  |> qcheck.apply(qcheck.option(bit_array()))
}

fn message_data() -> Generator(packet.MessageData) {
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

fn qos() -> Generator(packet.QoS) {
  from_list([packet.QoS0, packet.QoS1, packet.QoS2])
}

fn bit_array() -> Generator(BitArray) {
  use str <- qcheck.map(qcheck.string())
  bit_array.from_string(str)
}

fn mqtt_int() -> Generator(Int) {
  qcheck.int_uniform_inclusive(0, 65_535)
}

fn packet_id() -> Generator(Int) {
  qcheck.int_uniform_inclusive(1, 65_535)
}

fn from_list(values: List(a)) -> Generator(a) {
  let max_index = list.length(values) - 1
  use i <- qcheck.map(qcheck.int_uniform_inclusive(0, max_index))
  case list.drop(values, i) {
    [val, ..] -> val
    [] -> panic as "qcheck returned invalid value!"
  }
}
