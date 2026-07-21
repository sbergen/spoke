import gleam/erlang/process.{type Subject}
import spoke/mqtt
import spoke/mqtt_actor.{type TransportChannelConnector}

pub fn supervision_example(transport_connector: TransportChannelConnector) {
  let client_name = process.new_name("mqtt_client")
  let client_started: Subject(mqtt_actor.Client) = process.new_subject()

  let #(builder, _client) =
    transport_connector
    |> mqtt.connect_with_id("my_client_id")
    |> mqtt_actor.build()
    |> mqtt_actor.with_extra_init(fn(client) {
      process.send(client_started, client)
    })
    |> mqtt_actor.named(client_name)

  let _child_spec = mqtt_actor.supervised(builder, 100)
}
