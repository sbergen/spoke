import drift/record
import gleam/option.{None}
import spoke/core.{
  Connect, Handle, Perform, SubscribeToUpdates, TransportClosed,
  TransportEstablished, UnsubscribeFromUpdates,
}
import spoke/core/recorder
import spoke/mqtt
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn updates_subscribe_unsubscribe_test() {
  // This resets the ids, so do it before the discards
  let recorder =
    mqtt.connect_with_id(0, "my-client")
    |> recorder.from_options()

  let subscriber1 = record.discard()
  let subscriber2 = record.discard()

  let packet =
    server_out.Publish(
      packet.PublishDataQoS0(packet.MessageData(
        topic: "topic",
        payload: <<"payload">>,
        retain: False,
      )),
    )

  recorder
  |> record.input(Perform(SubscribeToUpdates(subscriber1)))
  |> record.input(Perform(SubscribeToUpdates(subscriber2)))
  |> record.input(Perform(Connect(True, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(UnsubscribeFromUpdates(subscriber2)))
  |> recorder.received(packet)
  |> record.input(Perform(UnsubscribeFromUpdates(subscriber1)))
  |> record.input(Handle(TransportClosed))
  |> recorder.snap("Updates can be subscribed and unsubscribed to")
}
