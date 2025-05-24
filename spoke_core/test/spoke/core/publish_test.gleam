import drift/record.{discard}
import spoke/core.{GetPendingPublishes, Perform, PublishMessage}
import spoke/core/recorder
import spoke/mqtt
import spoke/packet/server/outgoing as server_out

pub fn publish_qos0_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.AtMostOnce, False)

  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> recorder.snap("QoS0 publish")
}

pub fn publish_qos1_success_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False)

  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubAck(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("QoS1 publish success")
}
