import gleam/option.{None}
import spoke/core.{Connect, Perform, TransportEstablished}
import spoke/core/record.{type Recorder}
import spoke/mqtt
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

pub fn close_after_timeout_test() {
  set_up_connected(10)
  |> record.time_advance(10_000)
  |> record.time_advance(1000)
  |> record.snap("Connection is closed if ping times out")
}

fn set_up_connected(keep_alive: Int) -> Recorder {
  mqtt.connect_with_id(0, "ping-client")
  |> mqtt.keep_alive_seconds(keep_alive)
  |> mqtt.server_timeout_ms(1000)
  |> record.from_options()
  |> record.input(Perform(Connect(True, None)))
  |> record.input(TransportEstablished)
  |> record.received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.flush("connect and handshake")
}
