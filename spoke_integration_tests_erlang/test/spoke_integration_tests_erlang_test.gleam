import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleeunit
import gleeunit/should
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
    |> mqtt_actor.start_session

  connect_and_wait(client, True, None)
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)

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

  disconnect_and_wait(client)

  received_topic |> should.equal(topic)
  payload |> should.equal(<<"Hello from spoke!">>)
  retained |> should.equal(False)
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
    |> mqtt_actor.start_session

  // Connect and subscribe
  flush_server_state(receiver_client)
  connect_and_wait(receiver_client, False, None)
  let assert Ok(_) =
    mqtt_actor.subscribe(receiver_client, [mqtt.SubscribeRequest(topic, qos)])
    as "Subscribe should succeed"

  disconnect_and_wait(receiver_client)

  // Send the message

  let assert Ok(sender_client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("qos_sender")
    |> mqtt_actor.start_session
  connect_and_wait(sender_client, True, None)

  mqtt_actor.publish(
    sender_client,
    mqtt.PublishData(topic, <<"persisted msg">>, qos, False),
  )
  disconnect_and_wait(sender_client)

  // Now reconnect without cleaning session: the message should be received
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(receiver_client, updates)
  mqtt_actor.connect(receiver_client, False, None)
  assert process.receive(updates, 1000)
    == Ok(
      mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(mqtt.SessionPresent)),
    )

  let assert Ok(mqtt.ReceivedMessage("qos_topic", <<"persisted msg">>, False)) =
    process.receive(updates, 1000)
    as "QoS > 0 message should be received when reconnecting without cleaning session"

  disconnect_and_wait(receiver_client)
}

pub fn will_disconnect_test() -> Nil {
  let topic = "will_topic"

  let assert Ok(client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("will_receiver")
    |> mqtt_actor.start_session
  connect_and_wait(client, True, None)
  let assert Ok(_) =
    mqtt_actor.subscribe(client, [mqtt.SubscribeRequest(topic, mqtt.AtMostOnce)])

  // Subscribe to updates before triggering the will message
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)

  process.spawn_unlinked(fn() {
    let assert Ok(client) =
      tcp.connector_with_defaults("localhost")
      |> mqtt.connect_with_id("will_sender")
      |> mqtt_actor.start_session
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
    |> mqtt_actor.start_session

  connect_and_wait(client, True, None)
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)

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
  disconnect_and_wait(client)
}

fn flush_server_state(client: mqtt_actor.Client) -> Nil {
  // Connect with clean session set to true, then disconnect
  connect_and_wait(client, True, None)
  disconnect_and_wait(client)
}

fn connect_and_wait(
  client: mqtt_actor.Client,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Nil {
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)
  mqtt_actor.connect(client, clean_session, will)
  let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
    process.receive(updates, 1000)
    as "Should connect successfully"
  Nil
}

fn disconnect_and_wait(client: mqtt_actor.Client) -> Nil {
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)
  mqtt_actor.disconnect(client)
  let assert Ok(mqtt.ConnectionStateChanged(mqtt.Disconnected)) =
    process.receive(updates, 1000)
    as "Should disconnect successfully"
  Nil
}
