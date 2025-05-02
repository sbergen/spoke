import gleam/option.{None}
import spoke/core.{Connect, Perform, TransportEstablished}
import spoke/core/record.{type Recorder}
import spoke/packet
import spoke/packet/server/outgoing as server_out

pub fn pings_when_no_activity_test() {
  set_up_connected(10)
  |> record.time_advance(9999)
  |> record.time_advance(1)
  |> record.time_advance(100)
  |> record.received(server_out.PingResp)
  |> record.time_advance(9999)
  |> record.time_advance(1)
  |> record.time_advance(100)
  |> record.snap("Pings are sent when no other activity")
}

fn set_up_connected(keep_alive: Int) -> Recorder {
  let options =
    packet.ConnectOptions(False, "my-client", keep_alive, None, None)
  record.new()
  |> record.input(Perform(Connect(options)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.flush("connect and handshake")
}
