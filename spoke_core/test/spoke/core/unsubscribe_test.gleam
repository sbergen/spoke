import drift/record.{discard}
import gleam/option.{None}
import spoke/core.{Connect, Handle, Perform, TransportEstablished, Unsubscribe}
import spoke/core/recorder
import spoke/packet/server/outgoing as server_out

pub fn unsubscribe_when_not_connected_returns_error_test() {
  recorder.default()
  |> record.input(Perform(Connect(True, None)))
  |> record.input(Handle(TransportEstablished))
  |> record.input(Perform(Unsubscribe(["topic1"], discard())))
  |> recorder.snap("Unsubscribe when not connected is an error")
}

pub fn unsubscribe_success_test() {
  recorder.default_connected()
  |> record.input(Perform(Unsubscribe(["topic0", "topic1"], discard())))
  |> recorder.received(server_out.UnsubAck(1))
  |> recorder.snap("Successful unsubscribe")
}

pub fn unsubscribe_invalid_id_test() {
  recorder.default_connected()
  |> record.input(Perform(Unsubscribe(["topic0", "topic1"], discard())))
  |> recorder.received(server_out.UnsubAck(2))
  |> recorder.snap(
    "Unsubscribe ack with invalid packet id is protocol violation",
  )
}

pub fn unsubscribe_timeout_test() {
  recorder.default_connected()
  |> record.input(Perform(Unsubscribe(["topic0", "topic1"], discard())))
  |> record.time_advance(4999)
  |> record.time_advance(1)
  |> recorder.snap("Unsubscribe times out")
}
