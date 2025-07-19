import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/string
import spoke/mqtt
import spoke/mqtt_actor
import spoke/tcp

pub fn main() {
  let client_id = "spoke" <> string.inspect(int.random(999_999_999))
  let topic = "spoke-test"

  let assert Ok(client) =
    tcp.connector_with_defaults("broker.emqx.io")
    |> mqtt.connect_with_id(client_id)
    |> mqtt_actor.start_session(None)

  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)
  mqtt_actor.connect(client, True, None)

  let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
    process.receive(updates, 5000)

  let assert Ok(_) =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(topic, mqtt.ExactlyOnce),
    ])

  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtLeastOnce,
      retain: False,
    )
  mqtt_actor.publish(client, message)

  let message = process.receive(updates, 1000)
  io.println(string.inspect(message))

  mqtt_actor.disconnect(client)
}
