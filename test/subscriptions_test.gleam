import fake_server
import gleam/otp/task
import gleeunit/should
import spoke.{AtLeastOnce, AtMostOnce, ExactlyOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn subscribe_success_test() {
  let #(client, updates, socket) = fake_server.set_up_connected_client()

  let topics = [
    spoke.SubscribeRequest("topic0", AtMostOnce),
    spoke.SubscribeRequest("topic1", AtLeastOnce),
    spoke.SubscribeRequest("topic2", ExactlyOnce),
  ]
  let request_payload = [
    packet.SubscribeRequest("topic0", packet.QoS0),
    packet.SubscribeRequest("topic1", packet.QoS1),
    packet.SubscribeRequest("topic2", packet.QoS2),
  ]
  let results = [Ok(packet.QoS0), Ok(packet.QoS1), Ok(packet.QoS2)]

  let subscribe = task.async(fn() { spoke.subscribe(client, topics, 100) })
  fake_server.expect_packet(socket, server_in.Subscribe(1, request_payload))
  fake_server.send_response(socket, server_out.SubAck(1, results))

  let assert Ok(Ok(results)) = task.try_await(subscribe, 10)
  results
  |> should.equal([
    spoke.SuccessfulSubscription("topic0", AtMostOnce),
    spoke.SuccessfulSubscription("topic1", AtLeastOnce),
    spoke.SuccessfulSubscription("topic2", ExactlyOnce),
  ])

  fake_server.disconnect(client, updates, socket)
}
