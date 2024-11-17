import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleam/otp/task
import gleeunit/should
import spoke.{type Client, AtLeastOnce, AtMostOnce, ExactlyOnce}
import spoke/internal/packet
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/internal/transport

const id = "client-id"

pub fn connect_success_test() {
  let keep_alive_s = 15
  let #(client, sent_packets, receives, _, _) =
    set_up(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 1000) })

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request |> should.equal(outgoing.Connect(id, keep_alive_s))

  // Connect response
  simulate_server(receives, incoming.ConnAck(Ok(False)))

  let assert Ok(Ok(False)) = task.try_await(connect_task, 10)

  spoke.disconnect(client)
}

pub fn disconnects_after_server_rejects_connect_test() {
  let keep_alive_s = 15
  let #(client, _, receives, disconnects, updates) =
    set_up(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 10) })

  // Connect response
  simulate_server(
    receives,
    incoming.ConnAck(Error(incoming.BadUsernameOrPassword)),
  )

  let assert Ok(Error(spoke.BadUsernameOrPassword)) =
    task.try_await(connect_task, 10)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn aborted_connect_disconnects_with_correct_status_test() {
  let keep_alive_s = 15
  let #(client, _, connections, disconnects, updates) =
    set_up(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 10) })
  // Open channel
  let assert Ok(_) = process.receive(connections, 10)

  spoke.disconnect(client)

  let assert Ok(Error(spoke.DisconnectRequested)) =
    task.try_await(connect_task, 10)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn subscribe_success_test() {
  let #(client, sent_packets, receives, _, _) =
    set_up_connected(keep_alive: 1000, server_timeout: 100)

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
  simulate_server(receives, incoming.SubAck(expected_id, results))

  let assert Ok(Ok(results)) = task.try_await(subscribe, 10)
  results
  |> should.equal([
    spoke.SuccessfulSubscription("topic0", AtMostOnce),
    spoke.SuccessfulSubscription("topic1", AtLeastOnce),
    spoke.SuccessfulSubscription("topic2", ExactlyOnce),
  ])

  spoke.disconnect(client)
}

pub fn receive_message_test() {
  let #(client, _, receives, _, updates) =
    set_up_connected(keep_alive: 1000, server_timeout: 100)

  let data =
    packet.PublishData(
      topic: "topic0",
      payload: <<"payload">>,
      dup: True,
      qos: packet.QoS0,
      retain: False,
      packet_id: None,
    )

  simulate_server(receives, incoming.Publish(data))

  let assert Ok(spoke.ReceivedMessage(_, _, _)) = process.receive(updates, 10)

  spoke.disconnect(client)
}

pub fn publish_message_test() {
  let #(client, sent_packets, _, _, _) =
    set_up_connected(keep_alive: 1000, server_timeout: 100)

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

// The ping tests might be a bit flaky, as we are dealing with time.
// I couldn't find any easy way to fake time,
// and faking an interval became overly complicated.

// Note that keep_alive, has to be significantly longer than server_timeout,
// otherwise things get really racy.
// TODO: Add validation of user-passed arguments to these

pub fn pings_are_sent_when_no_other_activity_test() {
  let #(client, sent_packets, receives, _, _) =
    set_up_connected(keep_alive: 4, server_timeout: 2)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  simulate_server(receives, incoming.PingResp)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  simulate_server(receives, incoming.PingResp)

  spoke.disconnect(client)
}

pub fn pings_are_not_sent_when_has_other_activity_test() {
  let #(client, sent_packets, _, _, _) =
    set_up_connected(keep_alive: 4, server_timeout: 100)

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
    set_up_connected(keep_alive: 4, server_timeout: 1)

  let assert Ok(outgoing.PingReq) = process.receive(sent_packets, 6)
  let assert Ok(Nil) = process.receive(disconnects, 3)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

fn simulate_server(
  receives: Subject(Subject(incoming.Packet)),
  packet: incoming.Packet,
) -> Nil {
  let assert Ok(receiver) = process.receive(receives, 10)
  process.send(receiver, packet)
}

fn set_up_connected(
  keep_alive keep_alive: Int,
  server_timeout server_timeout: Int,
) -> #(
  Client,
  Subject(outgoing.Packet),
  Subject(Subject(incoming.Packet)),
  Subject(Nil),
  Subject(spoke.Update),
) {
  let #(client, sent_packets, receives, disconnects, updates) =
    set_up(keep_alive, server_timeout)
  let connect_task = task.async(fn() { spoke.connect(client, 10) })

  let assert Ok(outgoing.Connect(_, _)) = process.receive(sent_packets, 10)
  simulate_server(receives, incoming.ConnAck(Ok(False)))

  let assert Ok(Ok(_)) = task.try_await(connect_task, 10)
  #(client, sent_packets, receives, disconnects, updates)
}

fn set_up(
  keep_alive keep_alive: Int,
  server_timeout server_timeout: Int,
) -> #(
  Client,
  Subject(outgoing.Packet),
  Subject(Subject(incoming.Packet)),
  Subject(Nil),
  Subject(spoke.Update),
) {
  let outgoing = process.new_subject()
  let receives = process.new_subject()
  let disconnects = process.new_subject()
  let connect = fn() {
    transport.Channel(
      send: fn(packet) {
        process.send(outgoing, packet)
        Ok(Nil)
      },
      selecting_next: fn(state) {
        // We don't test chunking in these tests, should write them separately
        let assert <<>> = state

        // This subject needs to be created by the client process
        let incoming = process.new_subject()
        process.send(receives, incoming)

        process.new_selector()
        |> process.selecting(incoming, fn(packet) { #(<<>>, Ok([packet])) })
      },
      shutdown: fn() { process.send(disconnects, Nil) },
    )
  }

  let updates = process.new_subject()
  let client = spoke.run(id, keep_alive, server_timeout, connect, updates)
  #(client, outgoing, receives, disconnects, updates)
}
