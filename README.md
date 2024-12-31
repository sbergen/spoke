# spoke

Spoke is a MQTT client package very early in development,
written in Gleam.

You should probably not yet use it for anything important,
but feel free to try it out, and give feedback on anything!

Example usage:
```gleam
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import spoke

pub fn main() {
  let client_id = "spoke" <> string.inspect(int.random(999_999_999))
  let topic = "spoke-test"

  let connect_opts =
    spoke.ConnectOptions(
      client_id,
      keep_alive_seconds: 10,
      server_timeout_ms: 1000,
    )
  let transport_opts =
    spoke.TcpOptions("test.mosquitto.org", 1883, connect_timeout: 10_000)

  let updates = process.new_subject()
  let client = spoke.start(connect_opts, transport_opts, updates)
  spoke.connect(client)

  let assert Ok(_) =
    spoke.subscribe(
      client,
      [spoke.SubscribeRequest(topic, spoke.AtMostOnce)]
    )

  let message =
    spoke.PublishData(
      topic,
      <<"Hello from spoke!">>,
      spoke.AtMostOnce,
      retain: False,
    )
  spoke.publish(client, message)

  let assert Ok(spoke.ConnectionStateChanged(spoke.ConnectAccepted(_))) =
    process.receive(updates, 1000)

  let message = process.receive(updates, 1000)
  io.println(string.inspect(message))

  spoke.disconnect(client)
}
```

This should print the following,
assuming `test.mosquitto.org` is up (it's not rare for it to be down):
```
Ok(ReceivedMessage("spoke-test", "Hello from spoke!", False))
```

## Development status

Here's an overview of what MQTT features are implemented.
In summary, only QoS 0 over TCP with non-persistent sessions
is currently supported.

### MQTT features
- [x] Connect
  - [ ] Auth
- [x] Subscribe
- [x] Unsubscribe
- [x] Pings (keep alive)
- [x] Receive messages
- [x] Send messages
- [x] QoS 0
- [ ] QoS 1
- [ ] QoS 2
- [ ] Session management & reconnects (only required for QoS > 0?)
- [ ] Will

### Transport
- [x] TCP
- [ ] WebSocket

### General
- [ ] Better documentation of public parts of code
- [ ] Better error handling in client
- [ ] Graceful shutdown