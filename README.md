# gleamqtt

Gleamqtt is a MQTT client package very early in development,
written in Gleam.

You should probably not yet use it for anything important,
but feel free to try it out, and give feedback on anything!

Exmple usage:
```gleam
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import gleamqtt.{QoS0}
import gleamqtt/client
import gleamqtt/transport

pub fn main() {
  let client_id = "gleamqtt-" <> string.inspect(int.random(999_999_999))
  let topic = "gleamqtt-test"

  let connect_opts = gleamqtt.ConnectOptions(client_id, keep_alive: 60)
  let transport_opts =
    transport.TcpOptions(
      "test.mosquitto.org",
      1883,
      connect_timeout: 1000,
      send_timeout: 1000,
    )

  let updates = process.new_subject()
  let client = client.start(connect_opts, transport_opts, updates)
  let assert Ok(_) = client.connect(client, timeout: 1000)

  let assert Ok(_) =
    client.subscribe(client, [gleamqtt.SubscribeRequest(topic, QoS0)], 1000)

  let message =
    gleamqtt.PublishData(topic, <<"Hello from gleamqtt!">>, QoS0, retain: False)
  let assert Ok(_) = client.publish(client, message, 1000)

  let update = process.receive(updates, 1000)
  io.debug(update)
}
```

This should print
```
Ok(ReceivedMessage("gleamqtt-test", "Hello from gleamqtt!", False))
```

## Development status

Here's an overview of what MQTT features are implemented.
In summary, only QoS 0 over TCP with permanent subscriptions
is currently supported.
Also, since it doesn't yet do pings,
you should probably select a really big keep-alive value
(planning on fixing this soon).

### MQTT features
- [x] Connect
  - [ ] Auth
- [x] Subscribe
- [ ] Unsubscribe
- [ ] Pings (keep alive)
- [x] Receive messages
- [x] Send messages
- [ ] Session management & reconnects
- [x] QoS 0
- [ ] QoS 1
- [ ] QoS 2
- [ ] Will

### Transport
- [x] TCP
- [ ] WebSocket

### General
- [ ] Better documentation of public parts of code
- [ ] Better error handling in client
- [ ] Graceful shutdown