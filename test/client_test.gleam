import fake_interval.{type FakeInterval}
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{None, Some}
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

const keep_alive = 60

pub fn connect_success_test() {
  let #(client, pings, sent_packets, connections, _) = set_up()

  let connect_task = task.async(fn() { client.connect(client, 10) })

  // Open channel
  let assert Ok(server_out) = process.receive(connections, 10)

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request |> should.equal(outgoing.Connect(id, keep_alive))
  let assert None = fake_interval.get_interval(pings)

  // Connect response
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(Ok(False)) = task.try_await(connect_task, 10)
  fake_interval.get_interval(pings) |> should.equal(Some(keep_alive * 1000))
}

pub fn subscribe_success_test() {
  let #(client, _, sent_packets, server_out, _updates) = set_up_connected()

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
}

pub fn receive_message_test() {
  let #(_, _, _, server_out, updates) = set_up_connected()

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
}

pub fn publish_message_test() {
  let #(client, _, sent_packets, _, _) = set_up_connected()

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
}

pub fn pings_are_sent_when_no_other_activity_test() {
  let #(_, pings, sent_packets, server_out, _) = set_up_connected()

  fake_interval.timeout(pings)
  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 10)
  process.send(server_out, Ok(incoming.PingResp))

  fake_interval.timeout(pings)
  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 10)
  process.send(server_out, Ok(incoming.PingResp))
}

fn set_up_connected() -> #(
  Client,
  FakeInterval,
  Subject(outgoing.Packet),
  Receiver(incoming.Packet),
  Subject(client.Update),
) {
  let #(client, pings, sent_packets, connections, updates) = set_up()
  let connect_task = task.async(fn() { client.connect(client, 10) })

  let assert Ok(server_out) = process.receive(connections, 10)
  let assert Ok(outgoing.Connect(_, _)) = process.receive(sent_packets, 10)
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(Ok(_)) = task.try_await(connect_task, 10)
  let assert False = fake_interval.get_and_clear_reset(pings)
  #(client, pings, sent_packets, server_out, updates)
}

fn set_up() -> #(
  Client,
  FakeInterval,
  Subject(outgoing.Packet),
  Subject(Receiver(incoming.Packet)),
  Subject(client.Update),
) {
  let options = client.ConnectOptions(id, keep_alive)

  let send_to = process.new_subject()
  let connections = process.new_subject()
  let client_receives = process.new_subject()

  let connect = fn() {
    fake_channel.new(send_to, function.identity, connections)
  }

  let fake_interval = fake_interval.new()
  let start_interval = fn(action, interval) {
    fake_interval.start(fake_interval, action, interval)
  }

  let client = client.run(options, connect, start_interval, client_receives)
  #(client, fake_interval, send_to, connections, client_receives)
}
