//// These tests test the parts that can't be (reliably) tested with the
//// integration tests, which run against a real server.

import exemplify
import fake_server
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleeunit
import spoke/mqtt
import spoke/mqtt_actor
import spoke/packet
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out
import temporary

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn check_or_update_readme_test() {
  exemplify.update_or_check("../spoke_tcp/dev/example.gleam")
}

pub fn restore_session_from_file_test() -> Nil {
  let assert Ok(_) = {
    use filename <- temporary.create(temporary.file())
    let storage = mqtt_actor.persist_to_ets(filename)
    let #(connector, server) = fake_server.new()

    let assert Ok(started) =
      connector
      |> mqtt.connect_with_id("my-id")
      |> mqtt_actor.new_session(Some(storage))
      |> mqtt_actor.start(100)
    let client = started.data

    // Connect
    mqtt_actor.connect(client, False, None)
    let server =
      fake_server.establish_connection(server, Ok(packet.SessionNotPresent))

    // Start publish
    mqtt_actor.publish(
      client,
      mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False),
    )

    // Disconnect before ack and save to file
    mqtt_actor.disconnect(client)
    let server = fake_server.close(server)
    let assert Ok(Nil) = mqtt_actor.store_to_file(storage)
    mqtt_actor.delete_in_memory_storage(storage)

    // Restore session from file
    let assert Ok(storage) = mqtt_actor.load_ets_session_from_file(filename)
    let assert Ok(started) =
      connector
      |> mqtt.connect_with_id("my-id")
      |> mqtt_actor.restore_session(storage)
      |> mqtt_actor.start(100)
    let client = started.data

    // Connect
    mqtt_actor.connect(client, False, None)
    let server =
      server
      |> fake_server.flush
      |> fake_server.establish_connection(Ok(packet.SessionPresent))
    let assert [server_in.Connect(_)] = fake_server.receive(server)

    // Check that the packet is resent
    let expected_message = packet.MessageData("topic", <<"payload">>, False)
    assert fake_server.receive(server)
      == [server_in.Publish(packet.PublishDataQoS1(expected_message, True, 1))]
  }

  Nil
}

pub fn pending_publishes_test() -> Nil {
  let #(connector, server) = fake_server.new()
  let assert Ok(started) =
    connector
    |> mqtt.connect_with_id("my-id")
    |> mqtt_actor.new_session(None)
    |> mqtt_actor.start(100)
  let client = started.data

  // Connect
  mqtt_actor.connect(client, False, None)
  let server =
    fake_server.establish_connection(server, Ok(packet.SessionNotPresent))

  // Start 2 publishes
  mqtt_actor.publish(
    client,
    mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False),
  )
  mqtt_actor.publish(
    client,
    mqtt.PublishData("topic", <<"payload2">>, mqtt.AtLeastOnce, False),
  )

  assert // Assert the initial state and start waiting in another process
    mqtt_actor.pending_publishes(client) == 2
  let wait =
    run_task(fn() { mqtt_actor.wait_for_publishes_to_finish(client, 1000) })

  // Finish the first publish, assert state
  fake_server.send(server, server_out.PubAck(1))
  assert mqtt_actor.pending_publishes(client) == 1
  let assert Error(Nil) = process.receive(wait, 5)

  // Finish the second publish, assert state
  fake_server.send(server, server_out.PubAck(2))
  assert mqtt_actor.pending_publishes(client) == 0
  let assert Ok(Ok(Nil)) = process.receive(wait, 10)

  Nil
}

pub fn update_subscription_test() {
  let #(connector, server) = fake_server.new()
  let assert Ok(started) =
    connector
    |> mqtt.connect_with_id("my-id")
    |> mqtt_actor.new_session(None)
    |> mqtt_actor.start(100)
  let client = started.data

  // Subscribe to updates & Connect
  let updates1 = process.new_subject()
  let updates2 = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates1)
  let sub = mqtt_actor.subscribe_to_updates(client, updates2)
  mqtt_actor.connect(client, False, None)
  let server =
    fake_server.establish_connection(server, Ok(packet.SessionNotPresent))

  // Check that updates are received
  let expected_update =
    mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(mqtt.SessionNotPresent))
  assert process.receive(updates1, 10) == Ok(expected_update)
  assert process.receive(updates2, 10) == Ok(expected_update)

  // Unsubscribe one subject, and close connection
  mqtt_actor.unsubscribe_from_updates(client, sub)
  mqtt_actor.disconnect(client)
  fake_server.close(server)

  // Check that updates are(n't) received
  let expected_update = mqtt.ConnectionStateChanged(mqtt.Disconnected)
  assert process.receive(updates1, 10) == Ok(expected_update)
  assert process.receive(updates2, 1) == Error(Nil)
}

fn run_task(task: fn() -> a) -> Subject(a) {
  let result = process.new_subject()
  process.spawn(fn() { process.send(result, task()) })
  result
}
