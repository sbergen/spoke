import gleam/option.{None, Some}
import spoke/core.{
  Connect, Disconnect, Perform, TransportClosed, TransportEstablished,
  TransportFailed,
}
import spoke/core/record.{type Recorder}
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn connect_and_disconnect_test() {
  record.new()
  |> connect_with_password()
  |> record.input(Perform(Disconnect))
  |> record.input(TransportClosed)
  |> record.snap("Connect and Disconnect")
}

pub fn failed_auth_test() {
  record.new()
  |> fail_auth()
  |> record.snap("Failed connect closes transport")
}

pub fn reconnect_after_failure_test() {
  record.new()
  |> fail_auth()
  |> record.flush("failed auth")
  |> connect_with_password()
  |> record.snap("Reconnect after connect failure")
}

pub fn reconnect_after_protocol_violation_test() {
  record.new()
  |> protocol_violation_after_connect
  |> record.flush("protocol violation")
  |> connect_with_defaults()
  |> record.snap("Reconnect after protocol violation")
}

pub fn disconnect_before_establish_test() {
  record.new()
  |> record.input(Perform(Connect(default_options())))
  |> record.input(Perform(Disconnect))
  |> record.snap("Disconnect before connection established")
}

pub fn disconnect_while_connecting_test() {
  record.new()
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportEstablished)
  |> record.input(Perform(Disconnect))
  |> record.snap("Disconnect while connecting")
}

pub fn concurrent_connect_test() {
  record.new()
  |> record.input(Perform(Connect(default_options())))
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportEstablished)
  |> record.input(Perform(Connect(default_options())))
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.input(Perform(Connect(default_options())))
  |> record.snap("Concurrent connects are errors")
}

pub fn double_connack_test() {
  record.new()
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.snap("Double ConnAck is a protocol violation")
}

pub fn connack_before_connect_test() {
  record.new()
  |> record.input(Perform(Connect(default_options())))
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.snap("ConnAck before Connect is a protocol violation")
}

pub fn connack_must_be_first_test() {
  record.new()
  |> protocol_violation_after_connect
  |> record.snap("First packet from server MUST be ConnAck")
}

pub fn transport_error_during_connect_test() {
  record.new()
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportFailed("Fake failure"))
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportEstablished)
  |> record.input(TransportFailed("Fake failure"))
  |> record.snap("Transport failure during connect is published")
}

pub fn transport_error_while_disconnecting_test() {
  record.new()
  |> connect_with_defaults()
  |> record.flush("connect")
  |> record.input(Perform(Disconnect))
  |> record.input(TransportFailed("Fake failure"))
  |> record.snap("Transport failure while disconnecting is published")
}

fn protocol_violation_after_connect(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportEstablished)
  |> record.received(server_out.PingResp)
}

fn fail_auth(recorder: Recorder) -> Recorder {
  recorder
  |> record.input(Perform(Connect(default_options())))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Error(packet.BadUsernameOrPassword)))
}

fn connect_with_password(recorder: Recorder) -> Recorder {
  recorder
  |> connect_with_options(packet.ConnectOptions(
    False,
    "my-client",
    15,
    Some(packet.AuthOptions("username", Some(<<"password">>))),
    None,
  ))
}

fn connect_with_defaults(recorder: Recorder) -> Recorder {
  recorder |> connect_with_options(default_options())
}

fn connect_with_options(
  recorder: Recorder,
  options: packet.ConnectOptions,
) -> Recorder {
  recorder
  |> record.input(Perform(Connect(options)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
}

fn default_options() -> packet.ConnectOptions {
  packet.ConnectOptions(False, "my-client", 15, None, None)
}
