import drift/record.{discard}
import gleam/option.{None, Some}
import spoke/core.{
  Connect, Disconnect, Handle, Perform, TransportClosed, TransportEstablished,
  TransportFailed,
}
import spoke/core/recorder.{type Recorder}
import spoke/mqtt
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn connect_and_disconnect_test() {
  let will =
    mqtt.PublishData("will/topic", <<"will-data">>, mqtt.AtLeastOnce, False)

  mqtt.connect_with_id(0, "ping-client")
  |> mqtt.keep_alive_seconds(15)
  |> mqtt.using_auth("username", Some(<<"password">>))
  |> recorder.from_options()
  |> record.input(Perform(core.SubscribeToUpdates(record.discard())))
  |> record.input(Perform(Connect(False, Some(will))))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(Disconnect(discard())))
  |> record.input(Handle(TransportClosed))
  |> recorder.snap("Connect and Disconnect")
}

pub fn failed_auth_test() {
  recorder.default()
  |> fail_auth()
  |> recorder.snap("Failed connect closes transport")
}

pub fn reconnect_after_failure_test() {
  recorder.default()
  |> fail_auth()
  |> record.flush("failed auth")
  |> connect_with_defaults()
  |> recorder.snap("Reconnect after connect failure")
}

pub fn reconnect_after_protocol_violation_test() {
  recorder.default()
  |> protocol_violation_after_connect
  |> record.flush("protocol violation")
  |> connect_with_defaults()
  |> recorder.snap("Reconnect after protocol violation")
}

pub fn disconnect_before_connect_test() {
  recorder.default()
  |> record.input(Perform(Disconnect(discard())))
  |> recorder.snap("Disconnect before connecting")
}

pub fn disconnect_before_establish_test() {
  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Perform(Disconnect(discard())))
  |> recorder.snap("Disconnect before connection established")
}

pub fn disconnect_while_connecting_test() {
  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> record.input(Perform(Disconnect(discard())))
  |> recorder.snap("Disconnect while connecting")
}

pub fn concurrent_connect_test() {
  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> record.input(Perform(Connect(False, None)))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(Connect(False, None)))
  |> recorder.snap("Concurrent connects are no-ops")
}

pub fn double_connack_test() {
  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> recorder.snap("Double ConnAck is a protocol violation")
}

pub fn connack_before_connect_test() {
  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> recorder.snap("ConnAck before Connect is a protocol violation")
}

pub fn connack_must_be_first_test() {
  recorder.default()
  |> protocol_violation_after_connect
  |> recorder.snap("First packet from server MUST be ConnAck")
}

pub fn transport_error_during_connect_test() {
  recorder.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportFailed("Fake failure")))
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> record.input(Handle(TransportFailed("Fake failure")))
  |> recorder.snap("Transport failure during connect is published")
}

pub fn transport_error_while_disconnecting_test() {
  recorder.default()
  |> connect_with_defaults()
  |> record.flush("connect")
  |> record.input(Perform(Disconnect(discard())))
  |> record.input(Handle(TransportFailed("Fake failure")))
  |> recorder.snap("Transport failure while disconnecting is published")
}

pub fn connect_timeout_test() {
  mqtt.connect_with_id(0, "my-client")
  |> mqtt.server_timeout_ms(1000)
  |> recorder.from_options()
  |> record.input(Perform(core.SubscribeToUpdates(record.discard())))
  |> record.input(Perform(Connect(False, None)))
  |> record.time_advance(999)
  |> record.time_advance(1)
  |> record.input(Perform(Connect(False, None)))
  |> record.time_advance(500)
  |> record.input(Handle(TransportEstablished))
  |> record.time_advance(499)
  |> record.time_advance(1)
  |> recorder.snap("Connect can time out at all stages")
}

pub fn invalid_data_during_connect_test() {
  mqtt.connect_with_id(0, "my-client")
  |> mqtt.server_timeout_ms(1000)
  |> recorder.from_options()
  |> record.input(Perform(core.SubscribeToUpdates(record.discard())))
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> record.input(Handle(core.ReceivedData(<<1>>)))
  |> recorder.snap("Invalid data during handshake closes connection")
}

fn protocol_violation_after_connect(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.PingResp)
}

fn fail_auth(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Error(packet.BadUsernameOrPassword)))
}

fn connect_with_defaults(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
}
