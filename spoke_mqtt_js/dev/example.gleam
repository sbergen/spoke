import drift/js/channel
import gleam/int
import gleam/javascript/promise
import gleam/option.{None}
import gleam/string
import spoke/mqtt
import spoke/mqtt_js

pub fn main() {
  let client_id = "spoke" <> string.inspect(int.random(999_999_999))
  let topic = "spoke-test"

  let client =
    mqtt_js.using_websocket("ws://broker.emqx.io:8083/mqtt")
    |> mqtt.connect_with_id(client_id)
    |> mqtt_js.start_session()

  let #(updates, _) = mqtt_js.subscribe_to_updates(client)
  mqtt_js.connect(client, True, None)

  use update <- promise.await(channel.receive(updates, 1000))
  let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) = update

  use sub_result <- promise.await(
    mqtt_js.subscribe(client, [
      mqtt.SubscribeRequest(topic, mqtt.AtLeastOnce),
    ]),
  )
  let assert Ok(_) = sub_result

  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtLeastOnce,
      retain: False,
    )
  mqtt_js.publish(client, message)

  use message <- promise.await(channel.receive_forever(updates))
  let _ = echo message

  mqtt_js.disconnect(client)
}
