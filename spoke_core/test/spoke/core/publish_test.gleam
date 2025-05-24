import drift/record.{discard}
import gleam/option.{None}
import spoke/core.{
  Connect, GetPendingPublishes, Perform, PublishMessage, TransportClosed,
  TransportEstablished, WaitForPublishesToFinish,
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
  |> reconnect
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubAck(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("QoS1 republish after reconnect")
}

pub fn publish_qos2_happy_path_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.ExactlyOnce, False)
  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubRec(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubComp(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("QoS2 publish success")
}

pub fn publish_qos2_republish_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.ExactlyOnce, False)
  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(TransportClosed)
  |> reconnect
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubRec(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubComp(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("QoS2 republish after reconnect")
}

pub fn publish_qos2_rerelease_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.ExactlyOnce, False)
  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubRec(1))
  |> record.input(TransportClosed)
  |> reconnect
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.received(server_out.PubComp(1))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("QoS2 rerelease after reconnect")
}

pub fn clean_session_after_disconnected_test() {
  let data1 = mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False)
  let data2 =
    mqtt.PublishData("topic2", <<"payload2">>, mqtt.ExactlyOnce, False)

  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data1)))
  |> record.input(Perform(PublishMessage(data2)))
  |> record.input(TransportClosed)
  |> clean_reconnect
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("Reconnecting with clean session discards messages")
}

pub fn ephemeral_session_is_discarded_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False)
  recorder.default()
  |> record.input(Perform(Connect(True, None)))
  |> record.input(TransportEstablished)
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(TransportClosed)
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(GetPendingPublishes(discard())))
  |> recorder.snap("Ephemeral session is discarded on reconnect")
}

pub fn wait_for_publishes_to_finish_nothing_pending_test() {
  recorder.default_connected()
  |> record.input(Perform(WaitForPublishesToFinish(discard(), 0)))
  |> recorder.snap("Wait for publishes to finish when nothing pending")
}

pub fn wait_for_publishes_to_finish_happy_path_test() {
  let data1 = mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False)
  let data2 =
    mqtt.PublishData("topic2", <<"payload2">>, mqtt.ExactlyOnce, False)

  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data1)))
  |> record.input(Perform(PublishMessage(data2)))
  |> record.input(Perform(WaitForPublishesToFinish(discard(), 10)))
  |> record.input(Perform(WaitForPublishesToFinish(discard(), 10)))
  |> recorder.received(server_out.PubAck(1))
  |> recorder.received(server_out.PubRec(2))
  |> recorder.received(server_out.PubComp(2))
  |> recorder.snap("Wait for publishes to finish happy path")
}

pub fn wait_for_publishes_to_finish_timeout_test() {
  let data = mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False)

  recorder.default_connected()
  |> record.input(Perform(PublishMessage(data)))
  |> record.input(Perform(WaitForPublishesToFinish(discard(), 10)))
  |> record.time_advance(5)
  |> record.input(Perform(WaitForPublishesToFinish(discard(), 10)))
  |> record.time_advance(5)
  |> record.time_advance(5)
  |> recorder.snap("Wait for publishes to finish timeouts")
}

fn reconnect(recorder: recorder.Recorder) -> recorder.Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionPresent)))
}

fn clean_reconnect(recorder: recorder.Recorder) -> recorder.Recorder {
  recorder
  |> record.input(Perform(Connect(True, None)))
  |> record.input(TransportEstablished)
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
}
