import drift/record.{discard}
import gleam/option.{None}
import spoke/core.{
  Connect, GetPendingPublishes, Perform, PublishMessage, TransportClosed,
  TransportEstablished,
}
import spoke/core/recorder
import spoke/mqtt
import spoke/packet
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

pub fn resend_qos1_after_disconnected_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False)
  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(TransportClosed)
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionPresent)))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubAck(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("QoS1 republish after reconnect")
}
