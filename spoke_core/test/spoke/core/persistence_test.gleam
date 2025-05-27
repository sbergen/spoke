import drift
import drift/record.{discard}
import gleam/option.{None}
import spoke/core.{
  Connect, Disconnect, Perform, PublishMessage, TransportEstablished,
}
import spoke/core/recorder
import spoke/mqtt
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn restore_session_success_test() {
  let #(stepper, _) =
    mqtt.connect_with_id(0, "my-client")
    |> core.new_state()
    |> drift.new(Nil, Nil)

  // First session, no need to even connect
  let msg = mqtt.PublishData("topic", <<>>, mqtt.AtLeastOnce, False)
  let assert drift.Continue(_, stepper, _) =
    drift.step(stepper, 0, Perform(PublishMessage(msg)), core.handle_input)

  let assert drift.Continue([core.ReportStateAtDisconnect(action)], _, _) =
    drift.step(stepper, 0, Perform(Disconnect(discard())), core.handle_input)

  // Restore session
  recorder.from_state(action.argument)
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionPresent)))
  |> recorder.snap("Restore session with unsent message")
}

pub fn restore_session_failure_test() {
  let options = mqtt.connect_with_id(0, "my-client")
  let assert Error(_) = core.restore_state(options, "{ \"valid\": false }")
}
