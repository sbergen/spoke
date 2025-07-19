# spoke_mqtt_js

[![Package Version](https://img.shields.io/hexpm/v/spoke_mqtt_js)](https://hex.pm/packages/spoke_mqtt_js)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/spoke_mqtt_js/)

spoke_mqtt_js is a MQTT 3.1.1 client written in Gleam for the JavaScript runtime.
For similar functionality on the Erlang target, see 
[spoke_mqtt_actor](https://hexdocs.pm/spoke_mqtt_actor).

Example use:
```sh
gleam add spoke_mqtt@1
gleam add spoke_mqtt_js@1
gleam add drift_js@1
```
```gleam
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
```


## Design choices

Spoke aspires to be as high-level as possible, without being opinionated.
This means that the only things you'll need to handle yourself are
persistent session management (when to clean the session) and re-connections.
If you don't care about persistent sessions or overloading the server,
simply cleaning the session on each connect and
immediately reconnecting and resubscribing on unexpected disconnects should
give you a reliable client.

## Limitations

This package currently only supports WebSocket connections,
and does not provide a mechanism to persist sessions across application restarts.