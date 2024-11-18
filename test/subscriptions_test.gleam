import gleam/erlang/process
import gleam/otp/task
import gleeunit/should
import spoke.{AtLeastOnce, AtMostOnce, ExactlyOnce}
import spoke/internal/packet
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import test_client

pub fn subscribe_success_test() {
  let #(client, sent_packets, receives, _, _) =
    test_client.set_up_connected(keep_alive: 1000, server_timeout: 100)

  let topics = [
    spoke.SubscribeRequest("topic0", AtMostOnce),
    spoke.SubscribeRequest("topic1", AtLeastOnce),
    spoke.SubscribeRequest("topic2", ExactlyOnce),
  ]
  let request_payload = [
    outgoing.SubscribeRequest("topic0", packet.QoS0),
    outgoing.SubscribeRequest("topic1", packet.QoS1),
    outgoing.SubscribeRequest("topic2", packet.QoS2),
  ]
  let results = [
    incoming.SubscribeSuccess(packet.QoS0),
    incoming.SubscribeSuccess(packet.QoS1),
    incoming.SubscribeSuccess(packet.QoS2),
  ]

  let expected_id = 1

  let subscribe = task.async(fn() { spoke.subscribe(client, topics, 100) })

  let assert Ok(result) = process.receive(sent_packets, 10)
  result |> should.equal(outgoing.Subscribe(expected_id, request_payload))
  test_client.simulate_server_response(
    receives,
    incoming.SubAck(expected_id, results),
  )

  let assert Ok(Ok(results)) = task.try_await(subscribe, 10)
  results
  |> should.equal([
    spoke.SuccessfulSubscription("topic0", AtMostOnce),
    spoke.SuccessfulSubscription("topic1", AtLeastOnce),
    spoke.SuccessfulSubscription("topic2", ExactlyOnce),
  ])

  spoke.disconnect(client)
}
