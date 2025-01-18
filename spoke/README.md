# spoke

[![Package Version](https://img.shields.io/hexpm/v/spoke)](https://hex.pm/packages/spoke)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/spoke/)

Spoke is a MQTT 3.1.1 client written in Gleam for the Erlang runtime.

Example usage:

```sh
gleam add spoke
gleam add spoke_tcp
```

```gleam
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import spoke
import spoke/tcp

pub fn main() {
  let client_id = "spoke" <> string.inspect(int.random(999_999_999))
  let topic = "spoke-test"

  let client =
    tcp.connector_with_defaults("test.mosquitto.org")
    |> spoke.connect_with_id(client_id)
    |> spoke.start_session

  spoke.connect(client, True)

  let assert Ok(_) =
    spoke.subscribe(client, [spoke.SubscribeRequest(topic, spoke.AtLeastOnce)])

  let message =
    spoke.PublishData(
      topic,
      <<"Hello from spoke!">>,
      spoke.AtLeastOnce,
      retain: False,
    )
  spoke.publish(client, message)

  let updates = spoke.updates(client)

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

## Design choices

Spoke aspires to be as high-level as possible, without being opinionated.
This means that the only things you'll need to handle yourself are
persistent session management and re-connections.
If you don't care about persistent sessions or overloading the server,
simply cleaning the session on each connect and
immediately reconnecting on unexpected disconnects should give you a reliable client.

## Transport channels

The core `spoke` package is transport channel agnostic.
At the time of writing, `spoke_tcp` is the only implementation of transport channels for spoke.
Instead of using `spoke_tcp`, you can also bring your own transport channel.
See `TransportChannelConnector` for the required functions to make this work.

If you'd have use for a WebSocket channel,
please leave a feature request, and I might implement it.
