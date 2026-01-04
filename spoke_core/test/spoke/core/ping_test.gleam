import drift/record
import gleam/option.{None}
import spoke/core.{
  Connect, Handle, Perform, PublishMessage, TransportEstablished,
}
import spoke/core/recorder.{type Recorder}
import spoke/mqtt.{PublishData}
import spoke/packet.{
  MessageData, PublishDataQoS0, PublishDataQoS1, PublishDataQoS2,
}
import spoke/packet/server/outgoing as server_out

pub fn pings_when_no_activity_test() {
  set_up_connected(10)
  |> record.time_advance(9999)
  |> record.time_advance(1)
  |> record.time_advance(100)
  |> recorder.received(server_out.PingResp)
  |> record.time_advance(9899)
  |> record.time_advance(1)
  |> recorder.snap("Pings are sent when no other activity")
}

pub fn pings_when_only_incoming_activity_test() {
  set_up_connected(10)
  |> record.time_advance(9999)
  |> recorder.received(
    server_out.Publish(PublishDataQoS0(MessageData("topic", <<>>, False))),
  )
  |> record.time_advance(1)
  |> record.time_advance(100)
  |> recorder.received(server_out.PingResp)
  |> record.time_advance(9899)
  |> recorder.received(
    server_out.Publish(PublishDataQoS0(MessageData("topic", <<>>, False))),
  )
  |> record.time_advance(1)
  |> recorder.snap("Pings are sent when only incoming activity")
}

pub fn no_pings_when_other_outgoing_data_test() {
  set_up_connected(10)
  // Publish message right before timeout
  |> record.time_advance(9999)
  |> record.input(
    Perform(PublishMessage(PublishData("topic", <<>>, mqtt.AtMostOnce, False))),
  )
  // PubAck sent right before timeout
  |> record.time_advance(9999)
  |> recorder.received(
    server_out.Publish(PublishDataQoS1(
      MessageData("topic", <<>>, False),
      False,
      42,
    )),
  )
  // PubRec sent right before timeout
  |> record.time_advance(9999)
  |> recorder.received(
    server_out.Publish(PublishDataQoS2(
      MessageData("topic", <<>>, False),
      False,
      43,
    )),
  )
  // PubComp sent right before timeout
  |> record.time_advance(9999)
  |> recorder.received(server_out.PubRel(43))
  // PubRel send right before timeout (this is a bit artificial)
  |> record.time_advance(9999)
  |> recorder.received(server_out.PubRec(44))
  // Subscribe right before timeout
  |> record.time_advance(9999)
  |> record.input(
    Perform(core.Subscribe(
      [mqtt.SubscribeRequest("topic", mqtt.AtMostOnce)],
      record.discard(),
    )),
  )
  |> recorder.received(server_out.SubAck(1, Ok(packet.QoS0), []))
  // Unsubscribe right before timeout
  |> record.time_advance(9999)
  |> record.input(Perform(core.Unsubscribe(["topic"], record.discard())))
  |> recorder.received(server_out.UnsubAck(2))
  // And finally, if nothing happens, the ping should still be sent:
  |> record.time_advance(9999)
  |> record.time_advance(1)
  |> recorder.snap("Pings are not sent when there is other outgoing data")
}

pub fn close_after_timeout_test() {
  set_up_connected(10)
  |> record.time_advance(10_000)
  |> record.time_advance(1000)
  |> recorder.snap("Connection is closed if ping times out")
}

fn set_up_connected(keep_alive: Int) -> Recorder {
  mqtt.connect_with_id(0, "ping-client")
  |> mqtt.keep_alive_seconds(keep_alive)
  |> mqtt.server_timeout_ms(1000)
  |> recorder.from_options()
  |> record.input(Perform(core.SubscribeToUpdates(record.discard())))
  |> record.input(Perform(Connect(True, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.flush("connect and handshake")
}
