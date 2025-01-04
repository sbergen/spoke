import fake_server.{type ConnectedServer}
import gleam/erlang/process
import spoke.{AtMostOnce}
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

// The ping tests might be a bit flaky, as we are dealing with time.
// I couldn't find any easy way to fake time,
// and faking an interval became overly complicated.

// Note that keep_alive, has to be significantly longer than server_timeout,
// otherwise things get really racy.
// TODO: Add validation of user-passed arguments to these
const keep_alive = 50

const server_timeout = 10

pub fn pings_are_sent_when_no_other_activity_test() {
  let #(client, server) = set_up_connected()

  fake_server.expect_packet_timeout(server, keep_alive + 2, server_in.PingReq)
  fake_server.send_response(server, server_out.PingResp)

  fake_server.expect_packet_timeout(server, keep_alive + 2, server_in.PingReq)
  fake_server.send_response(server, server_out.PingResp)

  fake_server.expect_packet_timeout(server, keep_alive + 2, server_in.PingReq)
  fake_server.send_response(server, server_out.PingResp)

  fake_server.disconnect(client, server)
}

pub fn pings_are_not_sent_when_has_other_activity_test() {
  let #(client, server) = set_up_connected()

  let publish_data = spoke.PublishData("topic", <<>>, AtMostOnce, False)

  let is_publish = fn(packet: server_in.Packet) {
    case packet {
      server_in.Publish(_) -> True
      _ -> False
    }
  }

  // Send data at intervals less than the keep-alive
  spoke.publish(client, publish_data)
  fake_server.expect_packet_matching(server, is_publish)
  process.sleep(keep_alive / 2)

  spoke.publish(client, publish_data)
  fake_server.expect_packet_matching(server, is_publish)
  process.sleep(keep_alive / 2)

  spoke.publish(client, publish_data)
  fake_server.expect_packet_matching(server, is_publish)

  // The ping should be delayed
  process.sleep(keep_alive / 2)
  fake_server.assert_no_incoming_data(server)
  fake_server.expect_packet_timeout(server, keep_alive, server_in.PingReq)

  fake_server.disconnect(client, server)
}

pub fn connection_is_shut_down_if_no_pingresp_within_server_timeout_test() {
  let #(client, server) = set_up_connected()
  fake_server.expect_packet_timeout(server, keep_alive + 2, server_in.PingReq)
  process.sleep(server_timeout)

  fake_server.expect_connection_closed(server)

  let assert Ok(spoke.ConnectionStateChanged(spoke.DisconnectedUnexpectedly(_))) =
    process.receive(spoke.updates(client), 1)
}

fn set_up_connected() -> #(spoke.Client, ConnectedServer) {
  let server = fake_server.start_server()

  let client =
    spoke.start_with_ms_keep_alive(
      "ping-client",
      keep_alive,
      server_timeout,
      fake_server.default_options(server.port),
    )

  let #(server, _) = fake_server.connect_client(client, server, True, False)

  #(client, server)
}
