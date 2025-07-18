//// Tests that require a local MQTT broker running.

import drift/js/channel.{type Channel}
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/string
import spoke/mqtt.{ConnectAccepted, ConnectionStateChanged}
import spoke/mqtt_js

pub fn subscribe_and_publish_qos0_test() -> Promise(Nil) {
  use <- timeout(100)

  let client =
    mqtt_js.using_websocket("ws://localhost:8083/mqtt")
    |> mqtt.connect_with_id("subscribe_and_publish")
    |> mqtt_js.start_session()

  use updates <- promise.await(connect_and_wait(client, True, None))

  let topic = "subscribe_and_publish"
  use sub_result <- promise.await(
    mqtt_js.subscribe(client, [mqtt.SubscribeRequest(topic, mqtt.AtLeastOnce)]),
  )
  let assert Ok(_) = sub_result as "Should subscribe successfully"

  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtMostOnce,
      retain: False,
    )
  mqtt_js.publish(client, message)

  use update <- promise.await(channel.receive(updates, 1000))
  let assert Ok(mqtt.ReceivedMessage(received_topic, payload, retained)) =
    update
  disconnect_and_wait(client, updates)

  assert received_topic == topic
  assert payload == <<"Hello from spoke!">>
  assert retained == False

  promise.resolve(Nil)
}

pub fn receive_after_reconnect_qos0_test() -> Promise(Nil) {
  receive_after_reconnect(mqtt.AtMostOnce)
}

pub fn receive_after_reconnect_qos1_test() -> Promise(Nil) {
  receive_after_reconnect(mqtt.AtLeastOnce)
}

pub fn receive_after_reconnect_qos2_test() -> Promise(Nil) {
  receive_after_reconnect(mqtt.ExactlyOnce)
}

fn receive_after_reconnect(qos: mqtt.QoS) -> Promise(Nil) {
  use <- timeout(1000)
  let topic = string.inspect(qos)

  let receiver_client =
    mqtt_js.using_websocket("ws://localhost:8083/mqtt")
    |> mqtt.connect_with_id("qos_receiver_" <> topic)
    |> mqtt_js.start_session()

  // Connect and subscribe
  use _ <- promise.await(flush_server_state(receiver_client))
  use receiver_updates <- promise.await(connect_and_wait(
    receiver_client,
    False,
    None,
  ))
  use sub_result <- promise.await(
    mqtt_js.subscribe(receiver_client, [mqtt.SubscribeRequest(topic, qos)]),
  )
  let assert Ok(_) = sub_result as "Subscribe should succeed"

  use _ <- promise.await(disconnect_and_wait(receiver_client, receiver_updates))

  // Send the message

  let sender_client =
    mqtt_js.using_websocket("ws://localhost:8083/mqtt")
    |> mqtt.connect_with_id("qos_sender_" <> topic)
    |> mqtt_js.start_session()
  use sender_updates <- promise.await(connect_and_wait(
    sender_client,
    True,
    None,
  ))

  mqtt_js.publish(
    sender_client,
    mqtt.PublishData(topic, <<"persisted msg">>, qos, False),
  )
  use _ <- promise.await(mqtt_js.wait_for_publishes_to_finish(
    sender_client,
    100,
  ))
  use _ <- promise.await(disconnect_and_wait(sender_client, sender_updates))

  // Now reconnect without cleaning session: the message should be received
  mqtt_js.connect(receiver_client, False, None)
  use update <- promise.await(channel.receive_forever(receiver_updates))
  assert update
    == Ok(
      mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(mqtt.SessionPresent)),
    )

  use update <- promise.await(channel.receive_forever(receiver_updates))
  assert update == Ok(mqtt.ReceivedMessage(topic, <<"persisted msg">>, False))

  use _ <- promise.await(disconnect_and_wait(receiver_client, receiver_updates))
  promise.resolve(Nil)
}

pub fn will_disconnect_test() -> Promise(Nil) {
  use <- timeout(100)
  let topic = "will_topic"

  let client =
    mqtt_js.using_websocket("ws://localhost:8083/mqtt")
    |> mqtt.connect_with_id("will_receiver")
    |> mqtt_js.start_session()
  use updates <- promise.await(connect_and_wait(client, True, None))
  use sub_result <- promise.await(
    mqtt_js.subscribe(client, [mqtt.SubscribeRequest(topic, mqtt.AtMostOnce)]),
  )
  let assert Ok(_) = sub_result

  let sender_client =
    mqtt_js.using_websocket("ws://localhost:8083/mqtt")
    |> mqtt.connect_with_id("will_sender")
    |> mqtt_js.start_session()
  let will =
    mqtt.PublishData(topic, <<"will message">>, mqtt.AtLeastOnce, False)
  use _ <- promise.await(connect_and_wait(sender_client, True, Some(will)))

  // Subscribe with an invalid topic to get rejected
  let _ =
    mqtt_js.subscribe(sender_client, [
      mqtt.SubscribeRequest("/#/", mqtt.AtLeastOnce),
    ])

  use update <- promise.await(channel.receive(updates, 1000))
  let assert Ok(mqtt.ReceivedMessage(_, <<"will message">>, False)) = update
    as "Expected to receive will message"

  promise.resolve(Nil)
}

pub fn unsubscribe_test() -> Promise(Nil) {
  use <- timeout(100)
  let client =
    mqtt_js.using_websocket("ws://localhost:8083/mqtt")
    |> mqtt.connect_with_id("unsubscribe")
    |> mqtt_js.start_session()

  use updates <- promise.await(connect_and_wait(client, True, None))

  let topic = "unsubscribe"
  use sub_result <- promise.await(
    mqtt_js.subscribe(client, [mqtt.SubscribeRequest(topic, mqtt.AtLeastOnce)]),
  )
  let assert Ok(_) = sub_result as "Should subscribe successfully"

  use unsub_result <- promise.await(mqtt_js.unsubscribe(client, [topic]))
  let assert Ok(_) = unsub_result as "Should unsubscribe successfully"

  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtMostOnce,
      retain: False,
    )
  mqtt_js.publish(client, message)

  use update <- promise.await(channel.receive(updates, 10))
  assert update == Error(channel.ReceiveTimeout)
  use _ <- promise.map(disconnect_and_wait(client, updates))
  Nil
}

fn connect_and_wait(
  client: mqtt_js.Client,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Promise(Channel(mqtt.Update)) {
  let #(updates, _) = mqtt_js.subscribe_to_updates(client)
  mqtt_js.connect(client, clean_session, will)

  use update <- promise.map(channel.receive_forever(updates))
  let assert Ok(ConnectionStateChanged(ConnectAccepted(_))) = update
  updates
}

fn disconnect_and_wait(
  client: mqtt_js.Client,
  updates: Channel(mqtt.Update),
) -> Promise(Nil) {
  mqtt_js.disconnect(client)
  use result <- promise.map(channel.receive_forever(updates))
  assert result == Ok(mqtt.ConnectionStateChanged(mqtt.Disconnected))
  Nil
}

fn flush_server_state(client: mqtt_js.Client) -> Promise(Channel(mqtt.Update)) {
  // Connect with clean session set to true, then disconnect
  use updates <- promise.await(connect_and_wait(client, True, None))
  use _ <- promise.map(disconnect_and_wait(client, updates))
  updates
}

fn timeout(after: Int, body: fn() -> Promise(a)) -> Promise(a) {
  promise.race_list([
    promise.wait(after) |> promise.map(fn(_) { panic as "Timed out!" }),
    body(),
  ])
}
