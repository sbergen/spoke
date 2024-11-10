import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{None}
import gleam/otp/task
import gleeunit/should
import spoke.{type Update, QoS0, QoS1}
import spoke/client.{type Client}
import spoke/internal/packet
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/transport.{type Receiver}
import transport/fake_channel

const id = "client-id"

const keep_alive = 60

pub fn connect_success_test() {
  let #(client, sent_packets, connections, _updates) = set_up()

  let connect_task = task.async(fn() { client.connect(client, 10) })

  // Open channel
  let assert Ok(server_out) = process.receive(connections, 10)

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request |> should.equal(outgoing.Connect(id, keep_alive))

  // Connect response
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(Ok(False)) = task.try_await(connect_task, 10)
}

pub fn subscribe_success_test() {
  let #(client, sent_packets, server_out, _updates) = set_up_connected()

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
    spoke.SuccessfulSubscription("topic0", QoS0),
    spoke.SuccessfulSubscription("topic1", QoS1),
  ])
}

pub fn receive_message_test() {
  let #(_client, _sent_packets, server_out, updates) = set_up_connected()

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

  let assert Ok(spoke.ReceivedMessage(_, _, _)) = process.receive(updates, 10)
}

pub fn publish_message_test() {
  let #(client, sent_packets, _server_out, _updates) = set_up_connected()

  let data = spoke.PublishData("topic", <<"payload">>, QoS0, False)
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

fn set_up_connected() -> #(
  Client,
  Subject(outgoing.Packet),
  Receiver(incoming.Packet),
  Subject(Update),
) {
  let #(client, sent_packets, connections, updates) = set_up()
  let connect_task = task.async(fn() { client.connect(client, 10) })

  let assert Ok(server_out) = process.receive(connections, 10)
  let assert Ok(outgoing.Connect(_, _)) = process.receive(sent_packets, 10)
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(Ok(_)) = task.try_await(connect_task, 10)
  #(client, sent_packets, server_out, updates)
}

fn set_up() -> #(
  Client,
  Subject(outgoing.Packet),
  Subject(Receiver(incoming.Packet)),
  Subject(Update),
) {
  let options = spoke.ConnectOptions(id, keep_alive)

  let send_to = process.new_subject()
  let connections = process.new_subject()
  let client_receives = process.new_subject()

  let connect = fn() {
    fake_channel.new(send_to, function.identity, connections)
  }
  let client = client.run(options, connect, client_receives)
  #(client, send_to, connections, client_receives)
}
