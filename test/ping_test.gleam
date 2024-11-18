import gleam/erlang/process
import spoke.{AtMostOnce}
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import test_client

// The ping tests might be a bit flaky, as we are dealing with time.
// I couldn't find any easy way to fake time,
// and faking an interval became overly complicated.

// Note that keep_alive, has to be significantly longer than server_timeout,
// otherwise things get really racy.
// TODO: Add validation of user-passed arguments to these

pub fn pings_are_sent_when_no_other_activity_test() {
  let #(client, sent_packets, receives, _, _) =
    test_client.set_up_connected(keep_alive: 4, server_timeout: 2)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  test_client.simulate_server_response(receives, incoming.PingResp)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  test_client.simulate_server_response(receives, incoming.PingResp)

  spoke.disconnect(client)
}

pub fn pings_are_not_sent_when_has_other_activity_test() {
  let #(client, sent_packets, _, _, _) =
    test_client.set_up_connected(keep_alive: 4, server_timeout: 100)

  let publish_data = spoke.PublishData("topic", <<>>, AtMostOnce, False)

  // Send data at intevals less than the keep-alive
  let assert Ok(_) = spoke.publish(client, publish_data, 10)
  let assert Ok(outgoing.Publish(_)) = process.receive(sent_packets, 10)
  process.sleep(2)
  let assert Ok(_) = spoke.publish(client, publish_data, 10)
  let assert Ok(outgoing.Publish(_)) = process.receive(sent_packets, 10)
  process.sleep(2)
  let assert Ok(_) = spoke.publish(client, publish_data, 10)
  let assert Ok(outgoing.Publish(_)) = process.receive(sent_packets, 10)

  // The ping should be delayed
  let assert Error(_) = process.receive(sent_packets, 2)
  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 4)

  spoke.disconnect(client)
}

pub fn connection_is_shut_down_if_no_pingresp_within_server_timeout_test() {
  let #(_, sent_packets, _, disconnects, updates) =
    test_client.set_up_connected(keep_alive: 4, server_timeout: 1)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  let assert Ok(Nil) = process.receive(disconnects, 3)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}
