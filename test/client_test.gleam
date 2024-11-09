import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/otp/task
import gleamqtt.{type Update}
import gleamqtt/internal/client_impl.{type ClientImpl}
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/transport.{type Receiver}
import gleeunit/should
import transport/fake_channel

const id = "client-id"

const keep_alive = 60

pub fn connect_success_test() {
  let #(client, sent_packets, connections, _updates) = set_up()

  let connect_task = task.async(fn() { client_impl.connect(client, 10) })

  // Open channel
  let assert Ok(server_out) = process.receive(connections, 10)

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request |> should.equal(outgoing.Connect(id, keep_alive))

  // Connect response
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(_) = task.await(connect_task, 10)
}

pub fn subscribe_test() {
  let #(client, sent_packets, server_out, _updates) = set_up_connected()

  let topics = [gleamqtt.SubscribeRequest("topic", gleamqtt.QoS0)]
  let results = {
    use topic <- list.map(topics)
    incoming.SubscribeSuccess(topic.qos)
  }
  let expected_id = 0

  let subscribe =
    task.async(fn() { client_impl.subscribe(client, topics, 100) })

  let assert Ok(result) = process.receive(sent_packets, 10)
  result |> should.equal(outgoing.Subscribe(expected_id, topics))
  process.send(server_out, Ok(incoming.SubAck(expected_id, results)))

  task.await(subscribe, 10)
}

fn set_up_connected() -> #(
  ClientImpl,
  Subject(outgoing.Packet),
  Receiver(incoming.Packet),
  Subject(Update),
) {
  let #(client, sent_packets, connections, updates) = set_up()
  let connect_task = task.async(fn() { client_impl.connect(client, 10) })

  let assert Ok(server_out) = process.receive(connections, 10)
  let assert Ok(outgoing.Connect(_, _)) = process.receive(sent_packets, 10)
  process.send(server_out, Ok(incoming.ConnAck(Ok(False))))

  let assert Ok(_) = task.await(connect_task, 10)
  #(client, sent_packets, server_out, updates)
}

fn set_up() -> #(
  ClientImpl,
  Subject(outgoing.Packet),
  Subject(Receiver(incoming.Packet)),
  Subject(Update),
) {
  let options = gleamqtt.ConnectOptions(id, keep_alive)

  let send_to = process.new_subject()
  let connections = process.new_subject()
  let client_receives = process.new_subject()

  let connect = fn() {
    fake_channel.new(send_to, function.identity, connections)
  }
  let client = client_impl.run(options, connect, client_receives)
  #(client, send_to, connections, client_receives)
}
