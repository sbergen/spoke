import drift.{Continue}
import drift/record.{discard}
import gleam/bytes_tree
import gleam/list
import gleam/option.{None}
import spoke/core.{
  Connect, Disconnect, Handle, Perform, PublishMessage, TransportEstablished,
}
import spoke/core/ets_storage
import spoke/core/recorder
import spoke/mqtt
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn restore_session_success_test() {
  let storage = ets_storage.new()
  let #(stepper, _) =
    mqtt.connect_with_id(0, "my-client")
    |> core.new_state()
    |> drift.new(Nil)

  // Connect
  let connack =
    bytes_tree.to_bit_array(
      server_out.encode_packet(server_out.ConnAck(Ok(packet.SessionPresent))),
    )
  let stepper = step(stepper, storage, Perform(Connect(False, None)))
  let stepper = step(stepper, storage, Handle(TransportEstablished))
  let stepper = step(stepper, storage, Handle(core.ReceivedData(connack)))

  // Start publish and disconnect
  let msg = mqtt.PublishData("topic", <<>>, mqtt.AtLeastOnce, False)
  let stepper = step(stepper, storage, Perform(PublishMessage(msg)))
  step(stepper, storage, Perform(Disconnect(discard())))

  // Restore session
  recorder.from_state(ets_storage.read(storage))
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> recorder.received(server_out.ConnAck(Ok(packet.SessionPresent)))
  |> recorder.snap("Restore session with unsent message")

  ets_storage.delete(storage)
}

fn step(stepper, storage, input) {
  let assert Continue(outputs, stepper, _) =
    drift.step(stepper, 0, input, core.handle_input)

  list.each(outputs, fn(output) {
    case output {
      core.UpdatePersistedSession(update) -> ets_storage.update(storage, update)
      _ -> Nil
    }
  })

  stepper
}
