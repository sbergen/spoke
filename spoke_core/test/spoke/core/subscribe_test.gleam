import drift/record.{discard}
import gleam/option.{None}
import spoke/core.{Connect, Perform, Subscribe}
import spoke/core/recorder
import spoke/mqtt.{AtLeastOnce, AtMostOnce, ExactlyOnce}
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn subscribe_when_not_connected_test() {
  let request = mqtt.SubscribeRequest("topic0", mqtt.AtMostOnce)

  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Perform(Subscribe([request], discard())))
  |> recorder.snap("Subscribe before connection is established is an error")
}

pub fn subscribe_success_test() {
  let topics = [
    mqtt.SubscribeRequest("topic0", AtMostOnce),
    mqtt.SubscribeRequest("topic1", AtLeastOnce),
    mqtt.SubscribeRequest("topic2", ExactlyOnce),
  ]

  let results = [Ok(packet.QoS0), Ok(packet.QoS1), Ok(packet.QoS2)]
  let suback = server_out.SubAck(1, results)

  recorder.default_connected()
  |> record.input(Perform(Subscribe(topics, discard())))
  |> recorder.received(suback)
  |> recorder.snap("Subscribe success path")
}

pub fn subscribe_failed_test() {
  let topics = [
    mqtt.SubscribeRequest("topic0", AtMostOnce),
    mqtt.SubscribeRequest("topic1", AtLeastOnce),
  ]
  let results = [Ok(packet.QoS0), Error(Nil)]
  let suback = server_out.SubAck(1, results)

  recorder.default_connected()
  |> record.input(Perform(Subscribe(topics, discard())))
  |> recorder.received(suback)
  |> recorder.snap("Subscribe error from server")
}

pub fn subscribe_timeout_test() {
  let request = mqtt.SubscribeRequest("topic0", mqtt.AtMostOnce)

  recorder.default_connected()
  |> record.input(Perform(Subscribe([request], discard())))
  |> record.time_advance(4999)
  |> record.time_advance(1)
  |> recorder.snap("Subscribes time out after server timeout")
}

pub fn subscribe_invalid_id_test() {
  let request = mqtt.SubscribeRequest("topic0", mqtt.AtMostOnce)
  let suback = server_out.SubAck(2, [Ok(packet.QoS0)])

  recorder.default_connected()
  |> record.input(Perform(Subscribe([request], discard())))
  |> recorder.received(suback)
  |> record.time_advance(5000)
  |> recorder.snap("Invalid suback kills connection")
}

pub fn subscribe_invalid_length_test() {
  let request = mqtt.SubscribeRequest("topic0", mqtt.AtMostOnce)
  let suback = server_out.SubAck(1, [Ok(packet.QoS0), Ok(packet.QoS1)])

  recorder.default_connected()
  |> record.input(Perform(Subscribe([request], discard())))
  |> recorder.received(suback)
  |> record.time_advance(5000)
  |> recorder.snap("Invalid suback length kills connection")
}
