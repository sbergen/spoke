import gleam/option.{None, Some}
import spoke/core.{Connect, Disconnect, Perform, TransportEstablished}
import spoke/core/record.{type Recorder}
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn connect_and_disconnect_test() {
  record.new()
  |> connect_with_password()
  |> record.input(Perform(Disconnect))
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
  |> record.flush()
  |> connect_with_password()
  |> record.snap("Reconnect after failure")
}

fn fail_auth(recorder: Recorder) -> Recorder {
  let options = packet.ConnectOptions(False, "my-client", 15, None, None)

  recorder
  |> record.input(Perform(Connect(options)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Error(packet.BadUsernameOrPassword)))
}

fn connect_with_password(recorder: Recorder) -> Recorder {
  let options =
    packet.ConnectOptions(
      False,
      "my-client",
      15,
      Some(packet.AuthOptions("username", Some(<<"password">>))),
      None,
    )

  recorder
  |> record.input(Perform(Connect(options)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
}
