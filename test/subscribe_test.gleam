import fake_server
import gleam/erlang/process
import gleam/otp/task
import gleeunit/should
import spoke.{AtLeastOnce, AtMostOnce, ConnectionStateChanged, ExactlyOnce}
import spoke/internal/packet
import spoke/internal/packet/server/incoming as server_in
import spoke/internal/packet/server/outgoing as server_out

pub fn subscribe_when_not_connected_returns_error_test() {
  let client =
    spoke.start(
      spoke.ConnectOptions("client-id", 10, 100),
      fake_server.default_options(1883),
    )

  let assert Error(spoke.NotConnected) =
    spoke.subscribe(client, [spoke.SubscribeRequest("topic0", AtMostOnce)])
}

pub fn subscribe_success_test() {
  let #(client, socket) = fake_server.set_up_connected_client()

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

  let subscribe = task.async(fn() { spoke.subscribe(client, topics) })
  fake_server.expect_packet(socket, server_in.Subscribe(1, request_payload))
  fake_server.send_response(socket, server_out.SubAck(1, results))

  let assert Ok(Ok(results)) = task.try_await(subscribe, 10)
  results
  |> should.equal([
    spoke.SuccessfulSubscription("topic0", AtMostOnce),
    spoke.SuccessfulSubscription("topic1", AtLeastOnce),
    spoke.SuccessfulSubscription("topic2", ExactlyOnce),
  ])

  fake_server.disconnect(client, socket)
}

pub fn subscribe_failed_test() {
  let #(client, socket) = fake_server.set_up_connected_client()

  let topics = [
    spoke.SubscribeRequest("topic0", AtMostOnce),
    spoke.SubscribeRequest("topic1", AtLeastOnce),
  ]
  let results = [Ok(packet.QoS0), Error(Nil)]

  let subscribe = task.async(fn() { spoke.subscribe(client, topics) })
  fake_server.expect_any_packet(socket)
  fake_server.send_response(socket, server_out.SubAck(1, results))

  let assert Ok(Ok(results)) = task.try_await(subscribe, 10)
  results
  |> should.equal([
    spoke.SuccessfulSubscription("topic0", AtMostOnce),
    spoke.FailedSubscription,
  ])

  fake_server.disconnect(client, socket)
}

pub fn subscribe_timed_out_test() {
  let #(client, _socket) = fake_server.set_up_connected_client_with_timeout(5)

  let topics = [spoke.SubscribeRequest("topic0", AtMostOnce)]

  let subscribe = task.async(fn() { spoke.subscribe(client, topics) })

  let assert Ok(Error(spoke.OperationTimedOut)) = task.try_await(subscribe, 10)
  let assert Ok(ConnectionStateChanged(spoke.DisconnectedUnexpectedly(_))) =
    process.receive(spoke.updates(client), 10)
}

pub fn subscribe_invalid_id_test() {
  let #(client, socket) = fake_server.set_up_connected_client_with_timeout(5)

  let topics = [spoke.SubscribeRequest("topic0", AtMostOnce)]

  let subscribe = task.async(fn() { spoke.subscribe(client, topics) })
  fake_server.expect_any_packet(socket)
  fake_server.send_response(socket, server_out.SubAck(42, [Error(Nil)]))

  // We don't know where to respond, so this has to be a timeout
  let assert Ok(Error(spoke.OperationTimedOut)) = task.try_await(subscribe, 10)
  let assert Ok(ConnectionStateChanged(spoke.DisconnectedUnexpectedly(
    "Received invalid packet id in subscribe ack",
  ))) = process.receive(spoke.updates(client), 0)
}

pub fn subscribe_invalid_length_test() {
  let #(client, socket) = fake_server.set_up_connected_client_with_timeout(5)

  let topics = [spoke.SubscribeRequest("topic0", AtMostOnce)]

  let subscribe = task.async(fn() { spoke.subscribe(client, topics) })
  fake_server.expect_any_packet(socket)
  fake_server.send_response(
    socket,
    server_out.SubAck(1, [Error(Nil), Error(Nil)]),
  )

  let assert Ok(Error(spoke.ProtocolViolation)) = task.try_await(subscribe, 10)
  let assert Ok(ConnectionStateChanged(spoke.DisconnectedUnexpectedly(
    "Received invalid number of results in subscribe ack",
  ))) = process.receive(spoke.updates(client), 0)
}
