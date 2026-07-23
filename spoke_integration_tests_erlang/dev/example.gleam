import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/string
import spoke/mqtt
import spoke/mqtt_actor
import spoke/tcp

pub fn main() {
  // Generate a "unique" client ID.
  let client_id = "spoke" <> string.inspect(int.random(999_999_999))

  // Build a TCP connector and start the MQTT client actor.
  let assert Ok(started) =
    tcp.connector_with_defaults("broker.emqx.io")
    |> mqtt.connect_with_id(client_id)
    |> mqtt_actor.build()
    |> mqtt_actor.start(100)
  let client = started.data

  // Subscribe to incoming updates from the client.
  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)

  // Start connecting to the broker.
  mqtt_actor.connect(client, True, None)

  // Wait for the connection to be accepted within the given timeout.
  let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
    process.receive(updates, 5000)

  // Now that we are connected, let's subscribe to a topic.
  let topic = "spoke-test"
  let assert Ok([mqtt.SuccessfulSubscription(_, _)]) =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(topic, mqtt.ExactlyOnce),
    ])

  // Next, we publish a message to the topic we just subscribed to.
  let message =
    mqtt.PublishData(
      topic,
      <<"Hello from spoke!">>,
      mqtt.AtLeastOnce,
      retain: False,
    )
  mqtt_actor.publish(client, message)

  // Since we are subscribed to the topic,
  // the next update we receive should be the message we just sent
  // (or someone else's message!).
  let message = process.receive(updates, 1000)
  io.println(string.inspect(message))

  // Finally, we can cleanly disconnect from the broker.
  mqtt_actor.disconnect(client)
}
