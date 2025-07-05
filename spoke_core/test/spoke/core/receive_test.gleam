import drift/record.{discard}
import gleam/option.{None}
import spoke/core.{Connect, Disconnect, Handle, Perform, TransportEstablished}
import spoke/core/recorder
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn receive_message_qos0_test() {
  let packet =
    server_out.Publish(
      packet.PublishDataQoS0(packet.MessageData(
        topic: "topic",
        payload: <<"payload">>,
        retain: False,
      )),
    )

  recorder.default_connected()
  |> recorder.received(packet)
  |> recorder.snap("Receive QoS0 message")
}

pub fn receive_message_qos1_happy_path_test() {
  let packet =
    server_out.Publish(packet.PublishDataQoS1(
      packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False),
      False,
      42,
    ))

  recorder.default_connected()
  |> recorder.received(packet)
  |> recorder.snap("Receive QoS1 message")
}

pub fn receive_message_qos2_happy_path_test() {
  let packet =
    server_out.Publish(packet.PublishDataQoS2(
      packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False),
      False,
      42,
    ))

  recorder.default_connected()
  |> recorder.received(packet)
  |> recorder.received(server_out.PubRel(42))
  |> record.input(Perform(Disconnect(discard())))
  |> recorder.snap("Receive QoS2 message")
}

pub fn receive_message_qos2_duplicate_filtering_test() {
  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS2(msg, dup: False, packet_id: 42)
  let resend_data = packet.PublishDataQoS2(msg, dup: True, packet_id: 42)

  recorder.default_connected()
  |> recorder.received(server_out.Publish(data))
  |> record.input(Handle(core.TransportClosed))
  |> reconnect
  // Re-send data, as we didn't receive the PubRec
  |> recorder.received(server_out.Publish(resend_data))
  |> recorder.received(server_out.PubRel(42))
  |> record.input(Perform(Disconnect(discard())))
  |> recorder.snap("QoS2 duplicate is filtered when received after reconnect")
}

pub fn receive_message_qos2_duplicate_pubrel_test() {
  let msg =
    packet.MessageData(topic: "topic", payload: <<"payload">>, retain: False)
  let data = packet.PublishDataQoS2(msg, dup: False, packet_id: 42)

  recorder.default_connected()
  |> recorder.received(server_out.Publish(data))
  |> recorder.received(server_out.PubRel(42))
  |> record.input(Handle(core.TransportClosed))
  |> reconnect
  |> recorder.received(server_out.PubRel(42))
  |> record.input(Perform(Disconnect(discard())))
  |> recorder.snap("QoS2 pubrel is always responded to with pubcomp")
}

pub fn receive_invalid_data_while_connected_test() {
  recorder.default_connected()
  |> record.input(Handle(core.ReceivedData(<<1>>)))
  |> recorder.snap("Receiving invalid data while connected closes connection")
}

fn reconnect(recorder: recorder.Recorder) -> recorder.Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionPresent)))
}
