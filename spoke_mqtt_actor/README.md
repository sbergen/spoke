# spoke_mqtt_actor

[![Package Version](https://img.shields.io/hexpm/v/spoke_mqtt_actor)](https://hex.pm/packages/spoke_mqtt_actor)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/spoke_mqtt_actor/)

spoke_mqtt_actor is a MQTT 3.1.1 client written in Gleam for the Erlang runtime.
For similar functionality on the JavaScript target, see 
[spoke_mqtt_js](https://hexdocs.pm/spoke_mqtt_js).

Example usage:
```sh
gleam add spoke_mqtt@1
gleam add spoke_mqtt_actor@1
gleam add spoke_tcp@2
```
```gleam
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

  let assert Ok(started) =
    tcp.connector_with_defaults("broker.emqx.io")
    |> mqtt.connect_with_id(client_id)
    |> mqtt_actor.build()
    |> mqtt_actor.start(100)
  let client = started.data

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
```

This should print the following, assuming `broker.emqx.io` is up:
```
Ok(ReceivedMessage("spoke-test", "Hello from spoke!", False))
```

## Design choices

Spoke aspires to be as high-level as possible, without being opinionated.
This means that the only things you'll need to handle yourself are
persistent session management (when to clean the session) and re-connections.
If you don't care about persistent sessions or overloading the server,
simply cleaning the session on each connect and
immediately reconnecting and resubscribing on unexpected disconnects should
give you a reliable client.

## Transport channels

The `spoke_mqtt_actor` package is transport channel agnostic.
At the time of writing, `spoke_tcp` is the only implementation of a transport channel.
Instead of using `spoke_tcp`, you can also bring your own transport channel.
See `TransportChannelConnector` for the required functions to make this work.
