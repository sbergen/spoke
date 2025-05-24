import gleam/option.{None, Some}
import spoke/core.{
  Connect, Disconnect, Perform, TransportClosed, TransportEstablished,
  TransportFailed,
}
import spoke/core/record.{type Recorder}
import spoke/mqtt
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn connect_and_disconnect_test() {
  let will =
    mqtt.PublishData("will/topic", <<"will-data">>, mqtt.AtLeastOnce, False)

  mqtt.connect_with_id(0, "ping-client")
  |> mqtt.keep_alive_seconds(15)
  |> mqtt.using_auth("username", Some(<<"password">>))
  |> record.from_options()
  |> record.input(Perform(Connect(False, Some(will))))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(Disconnect))
  |> record.input(TransportClosed)
  |> record.snap("Connect and Disconnect")
}

pub fn failed_auth_test() {
  record.default()
  |> fail_auth()
  |> record.snap("Failed connect closes transport")
}

pub fn reconnect_after_failure_test() {
  record.default()
  |> fail_auth()
  |> record.flush("failed auth")
  |> connect_with_defaults()
  |> record.snap("Reconnect after connect failure")
}

pub fn reconnect_after_protocol_violation_test() {
  record.default()
  |> protocol_violation_after_connect
  |> record.flush("protocol violation")
  |> connect_with_defaults()
  |> record.snap("Reconnect after protocol violation")
}

pub fn disconnect_before_establish_test() {
  record.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Perform(Disconnect))
  |> record.snap("Disconnect before connection established")
}

pub fn disconnect_while_connecting_test() {
  record.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.input(Perform(Disconnect))
  |> record.snap("Disconnect while connecting")
}

pub fn concurrent_connect_test() {
  record.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.input(Perform(Connect(False, None)))
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(Connect(False, None)))
  |> record.snap("Concurrent connects are no-ops")
}

pub fn double_connack_test() {
  record.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.snap("Double ConnAck is a protocol violation")
}

pub fn connack_before_connect_test() {
  record.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.snap("ConnAck before Connect is a protocol violation")
}

pub fn connack_must_be_first_test() {
  record.default()
  |> protocol_violation_after_connect
  |> record.snap("First packet from server MUST be ConnAck")
}

pub fn transport_error_during_connect_test() {
  record.default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportFailed("Fake failure"))
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.input(TransportFailed("Fake failure"))
  |> record.snap("Transport failure during connect is published")
}

pub fn transport_error_while_disconnecting_test() {
  record.default()
  |> connect_with_defaults()
  |> record.flush("connect")
  |> record.input(Perform(Disconnect))
  |> record.input(TransportFailed("Fake failure"))
  |> record.snap("Transport failure while disconnecting is published")
}

pub fn connect_timeout_test() {
  mqtt.connect_with_id(0, "my-client")
  |> mqtt.server_timeout_ms(1000)
  |> record.from_options()
  |> record.input(Perform(Connect(False, None)))
  |> record.time_advance(999)
  |> record.time_advance(1)
  |> record.input(Perform(Connect(False, None)))
  |> record.time_advance(500)
  |> record.input(TransportEstablished)
  |> record.time_advance(499)
  |> record.time_advance(1)
  |> record.snap("Connect can time out at all stages")
}

fn protocol_violation_after_connect(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.PingResp)
}

fn fail_auth(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Error(packet.BadUsernameOrPassword)))
}

fn connect_with_defaults(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
}
