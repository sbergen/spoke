import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{None}
import gleam/otp/task
import gleeunit/should
import spoke.{QoS0, QoS1}
import spoke/client.{type Client}
import spoke/internal/packet
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/transport.{type Receiver}
import transport/fake_channel

const id = "client-id"

pub fn connect_success_test() {
  let keep_alive_s = 15
  let #(client, sent_packets, connections, _, _) =
    set_up(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { client.connect(client, 10) })

  // Open channel
  let assert Ok(server_out) = process.receive(connections, 10)

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request |> should.equal(outgoing.Connect(id, keep_alive_s))

  // Connect response
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(Ok(False)) = task.try_await(connect_task, 10)

  client.disconnect(client)
}

pub fn subscribe_success_test() {
  let #(client, sent_packets, server_out, _, _) =
    set_up_connected(keep_alive: 1000, server_timeout: 100)

  let topics = [
    spoke.SubscribeRequest("topic0", QoS0),
    spoke.SubscribeRequest("topic1", QoS1),
  ]
  let results = {
    use topic <- list.map(topics)
    incoming.SubscribeSuccess(topic.qos)
  }
  let expected_id = 1

  let subscribe = task.async(fn() { client.subscribe(client, topics, 100) })

  let assert Ok(result) = process.receive(sent_packets, 10)
  result |> should.equal(outgoing.Subscribe(expected_id, topics))
  process.send(server_out, Ok(incoming.SubAck(expected_id, results)))

  let assert Ok(Ok(results)) = task.try_await(subscribe, 10)
  results
  |> should.equal([
    client.SuccessfulSubscription("topic0", QoS0),
    client.SuccessfulSubscription("topic1", QoS1),
  ])

  client.disconnect(client)
}

pub fn receive_message_test() {
  let #(client, _, server_out, _, updates) =
    set_up_connected(keep_alive: 1000, server_timeout: 100)

  let data =
    packet.PublishData(
      topic: "topic0",
      payload: <<"payload">>,
      dup: True,
      qos: QoS0,
      retain: False,
      packet_id: None,
    )
  process.send(server_out, Ok(incoming.Publish(data)))

  let assert Ok(client.ReceivedMessage(_, _, _)) = process.receive(updates, 10)

  client.disconnect(client)
}

pub fn publish_message_test() {
  let #(client, sent_packets, _, _, _) =
    set_up_connected(keep_alive: 1000, server_timeout: 100)

  let data = client.PublishData("topic", <<"payload">>, QoS0, False)
  let assert Ok(_) = client.publish(client, data, 10)

  let assert Ok(outgoing.Publish(data)) = process.receive(sent_packets, 10)
  data
  |> should.equal(packet.PublishData(
    "topic",
    <<"payload">>,
    False,
    QoS0,
    False,
    None,
  ))

  client.disconnect(client)
}

// The ping tests might be a bit flaky, as we are dealing with time.
// I couldn't find any easy way to fake time,
// and faking an interval became overly complicated.

// Note that keep_alive, has to be significantly longer than server_timeout,
// otherwise things get really racy.
// TODO: Add validation of user-passed arguments to these

pub fn pings_are_sent_when_no_other_activity_test() {
  let #(client, sent_packets, server_out, _, _) =
    set_up_connected(keep_alive: 4, server_timeout: 2)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  process.send(server_out, Ok(incoming.PingResp))

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  process.send(server_out, Ok(incoming.PingResp))

  client.disconnect(client)
}

pub fn pings_are_not_sent_when_has_other_activity_test() {
  let #(client, sent_packets, _, _, _) =
    set_up_connected(keep_alive: 4, server_timeout: 100)

  let publish_data = client.PublishData("topic", <<>>, QoS0, False)

  // Send data at intevals less than the keep-alive
  let assert Ok(_) = client.publish(client, publish_data, 10)
  let assert Ok(outgoing.Publish(_)) = process.receive(sent_packets, 10)
  process.sleep(2)
  let assert Ok(_) = client.publish(client, publish_data, 10)
  let assert Ok(outgoing.Publish(_)) = process.receive(sent_packets, 10)
  process.sleep(2)
  let assert Ok(_) = client.publish(client, publish_data, 10)
  let assert Ok(outgoing.Publish(_)) = process.receive(sent_packets, 10)

  // The ping should be delayed
  let assert Error(_) = process.receive(sent_packets, 2)
  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 4)

  client.disconnect(client)
}

pub fn connection_is_shut_down_if_no_pingresp_within_server_timeout_test() {
  let #(_, sent_packets, _, disconnects, updates) =
    set_up_connected(keep_alive: 4, server_timeout: 1)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  let assert Ok(Nil) = process.receive(disconnects, 3)
  let assert Ok(client.Disconnected) = process.receive(updates, 1)
}

fn set_up_connected(
  keep_alive keep_alive: Int,
  server_timeout server_timeout: Int,
) -> #(
  Client,
  Subject(outgoing.Packet),
  Receiver(incoming.Packet),
  Subject(Nil),
  Subject(client.Update),
) {
  let #(client, sent_packets, connections, disconnects, updates) =
    set_up(keep_alive, server_timeout)
  let connect_task = task.async(fn() { client.connect(client, 10) })

  let assert Ok(server_out) = process.receive(connections, 10)
  let assert Ok(outgoing.Connect(_, _)) = process.receive(sent_packets, 10)
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(Ok(_)) = task.try_await(connect_task, 10)
  #(client, sent_packets, server_out, disconnects, updates)
}

fn set_up(
  keep_alive keep_alive: Int,
  server_timeout server_timeout: Int,
) -> #(
  Client,
  Subject(outgoing.Packet),
  Subject(Receiver(incoming.Packet)),
  Subject(Nil),
  Subject(client.Update),
) {
  let send_to = process.new_subject()
  let updates = process.new_subject()

  let connections = process.new_subject()
  let disconnects = process.new_subject()
  let connect = fn() {
    fake_channel.new(send_to, function.identity, connections, fn() {
      process.send(disconnects, Nil)
    })
  }

  let client = client.run(id, keep_alive, server_timeout, connect, updates)
  #(client, send_to, connections, disconnects, updates)
}
