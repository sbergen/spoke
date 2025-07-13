import fake_server
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

pub fn restore_session_from_file_test() -> Nil {
  let assert Ok(_) = {
    use filename <- temporary.create(temporary.file())
    let storage = mqtt_actor.persist_to_ets(filename)
    let #(connector, channel) = fake_server.new()

    let assert Ok(client) =
      connector
      |> mqtt.connect_with_id("my-id")
      |> mqtt_actor.start_session(Some(storage))

    // Connect
    mqtt_actor.connect(client, False, None)

    let channel =
      channel
      |> fake_server.connected
      |> fake_server.send(server_out.ConnAck(Ok(packet.SessionNotPresent)))

    // Start publish
    mqtt_actor.publish(
      client,
      mqtt.PublishData("topic", <<"payload">>, mqtt.AtLeastOnce, False),
    )

    // Disconnect before ack and save to file
    mqtt_actor.disconnect(client)
    let channel = fake_server.close(channel)
    let assert Ok(Nil) = mqtt_actor.store_to_file(storage)
    mqtt_actor.delete_in_memory_storage(storage)

    // Restore session from file
    let assert Ok(storage) = mqtt_actor.load_ets_session_from_file(filename)
    let assert Ok(client) =
      connector
      |> mqtt.connect_with_id("my-id")
      |> mqtt_actor.restore_session(storage)

    // Connect
    mqtt_actor.connect(client, False, None)
    let channel =
      channel
      |> fake_server.flush
      |> fake_server.connected
      |> fake_server.send(server_out.ConnAck(Ok(packet.SessionPresent)))

    let assert [server_in.Connect(_)] = fake_server.receive(channel)

    // Check that the packet is resent
    let expected_message = packet.MessageData("topic", <<"payload">>, False)
    assert fake_server.receive(channel)
      == [server_in.Publish(packet.PublishDataQoS1(expected_message, True, 1))]
  }

  Nil
}
