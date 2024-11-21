import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import spoke.{AtMostOnce}
import spoke/internal/packet
import spoke/internal/packet/client/outgoing
import test_client

pub fn publish_message_test() {
  let #(client, sent_packets, _, _, _) =
    test_client.set_up_connected(keep_alive: 1000, server_timeout: 100)

  let data = spoke.PublishData("topic", <<"payload">>, AtMostOnce, False)
  let assert Ok(_) = spoke.publish(client, data, 10)

  let assert Ok(outgoing.Publish(data)) = process.receive(sent_packets, 10)
  data
  |> should.equal(packet.PublishData(
    "topic",
    <<"payload">>,
    False,
    packet.QoS0,
    False,
    None,
  ))

  spoke.disconnect(client)
}

pub fn publish_timeout_disconnects_test() {
  let #(client, _, _, disconnects, updates) =
    test_client.set_up_connected(keep_alive: 1000, server_timeout: 100)

  let data = spoke.PublishData("topic", <<>>, AtMostOnce, False)
  let assert Error(spoke.PublishTimedOut) = spoke.publish(client, data, 0)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}
