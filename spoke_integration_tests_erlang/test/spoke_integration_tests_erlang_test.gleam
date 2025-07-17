import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleeunit
import spoke/mqtt
import spoke/mqtt_actor
import spoke/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn subscribe_and_publish_qos0_test() -> Nil {
  let assert Ok(client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("subscribe_and_publish")
    |> mqtt_actor.start_session(None)

  let updates = connect_and_wait(client, True, None)

  let topic = "subscribe_and_publish"
  let assert Ok(_) =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(topic, mqtt.AtLeastOnce),
    ])
    as "Should subscribe successfully"

  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtMostOnce,
      retain: False,
    )
  mqtt_actor.publish(client, message)

  let assert Ok(mqtt.ReceivedMessage(received_topic, payload, retained)) =
    process.receive(updates, 1000)

  disconnect_and_wait(client, updates)

  assert received_topic == topic
  assert payload == <<"Hello from spoke!">>
  assert retained == False
}

pub fn receive_after_reconnect_qos0_test() -> Nil {
  receive_after_reconnect(mqtt.AtMostOnce)
}

pub fn receive_after_reconnect_qos1_test() -> Nil {
  receive_after_reconnect(mqtt.AtLeastOnce)
}

pub fn receive_after_reconnect_qos2_test() -> Nil {
  receive_after_reconnect(mqtt.ExactlyOnce)
}

fn receive_after_reconnect(qos: mqtt.QoS) -> Nil {
  let topic = "qos_topic"

  let assert Ok(receiver_client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("qos_receiver")
    |> mqtt_actor.start_session(None)

  // Connect and subscribe
  flush_server_state(receiver_client)
  let receiver_updates = connect_and_wait(receiver_client, False, None)
  let assert Ok(_) =
    mqtt_actor.subscribe(receiver_client, [mqtt.SubscribeRequest(topic, qos)])
    as "Subscribe should succeed"

  disconnect_and_wait(receiver_client, receiver_updates)

  // Send the message

  let assert Ok(sender_client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("qos_sender")
    |> mqtt_actor.start_session(None)
  let sender_updates = connect_and_wait(sender_client, True, None)

  mqtt_actor.publish(
    sender_client,
    mqtt.PublishData(topic, <<"persisted msg">>, qos, False),
  )
  disconnect_and_wait(sender_client, sender_updates)

  // Now reconnect without cleaning session: the message should be received
  mqtt_actor.connect(receiver_client, False, None)
  assert process.receive(receiver_updates, 1000)
    == Ok(
      mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(mqtt.SessionPresent)),
    )

  let assert Ok(mqtt.ReceivedMessage("qos_topic", <<"persisted msg">>, False)) =
    process.receive(receiver_updates, 1000)
    as "QoS > 0 message should be received when reconnecting without cleaning session"

  disconnect_and_wait(receiver_client, receiver_updates)
}

pub fn will_disconnect_test() -> Nil {
  let topic = "will_topic"

  let assert Ok(client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("will_receiver")
    |> mqtt_actor.start_session(None)
  let updates = connect_and_wait(client, True, None)
  let assert Ok(_) =
    mqtt_actor.subscribe(client, [mqtt.SubscribeRequest(topic, mqtt.AtMostOnce)])

  process.spawn_unlinked(fn() {
    let assert Ok(client) =
      tcp.connector_with_defaults("localhost")
      |> mqtt.connect_with_id("will_sender")
      |> mqtt_actor.start_session(None)
    let will =
      mqtt.PublishData(topic, <<"will message">>, mqtt.AtLeastOnce, False)
    connect_and_wait(client, True, Some(will))

    // Subscribe with an invalid topic to get rejected
    let _ =
      mqtt_actor.subscribe(client, [
        mqtt.SubscribeRequest("/#/", mqtt.AtLeastOnce),
      ])
    process.sleep(100)
  })

  let assert Ok(mqtt.ReceivedMessage(_, <<"will message">>, False)) =
    process.receive(updates, 1000)
    as "Expected to receive will message"

  Nil
}

pub fn unsubscribe_test() -> Nil {
  let assert Ok(client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("unsubscribe")
    |> mqtt_actor.start_session(None)

  let updates = connect_and_wait(client, True, None)

  let topic = "unsubscribe"
  let assert Ok(_) =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(topic, mqtt.AtLeastOnce),
    ])
    as "Should subscribe successfully"

  let assert Ok(_) = mqtt_actor.unsubscribe(client, [topic])
    as "Should unsubscribe successfully"

  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtMostOnce,
      retain: False,
    )
  mqtt_actor.publish(client, message)

  assert process.receive(updates, 100) == Error(Nil)
  disconnect_and_wait(client, updates)
}

fn flush_server_state(client: mqtt_actor.Client) -> Subject(mqtt.Update) {
  // Connect with clean session set to true, then disconnect
  let updates = connect_and_wait(client, True, None)
  disconnect_and_wait(client, updates)
  updates
}

fn connect_and_wait(
  client: mqtt_actor.Client,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Subject(mqtt.Update) {
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)
  mqtt_actor.connect(client, clean_session, will)
  let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
    process.receive(updates, 1000)
    as "Should connect successfully"
  updates
}

fn disconnect_and_wait(
  client: mqtt_actor.Client,
  updates: Subject(mqtt.Update),
) -> Nil {
  mqtt_actor.disconnect(client)
  let assert Ok(mqtt.ConnectionStateChanged(mqtt.Disconnected)) =
    process.receive(updates, 1000)
    as "Should disconnect successfully"
  Nil
}
