//// Tests that require a local MQTT broker running.

import drift/js/channel
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None}
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

fn connect_and_wait(
  client: mqtt_js.Client,
  clean_session: Bool,
  will: Option(mqtt.PublishData),
) -> Promise(channel.Channel(mqtt.Update)) {
  let #(updates, _) = mqtt_js.subscribe_to_updates(client)
  mqtt_js.connect(client, clean_session, will)

  use update <- promise.map(channel.receive_forever(updates))
  let assert Ok(ConnectionStateChanged(ConnectAccepted(_))) = update
  updates
}

fn disconnect_and_wait(
  client: mqtt_js.Client,
  updates: channel.Channel(mqtt.Update),
) -> Promise(Nil) {
  mqtt_js.disconnect(client)
  use result <- promise.map(channel.receive_forever(updates))
  assert result == Ok(mqtt.ConnectionStateChanged(mqtt.Disconnected))
  Nil
}

fn timeout(after: Int, body: fn() -> Promise(a)) -> Promise(a) {
  promise.race_list([
    promise.wait(after) |> promise.map(fn(_) { panic as "Timed out!" }),
    body(),
  ])
}
