import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import spoke/mqtt
import spoke/mqtt_actor

pub fn main() -> Nil {
  //gleeunit.main()

  let assert Ok(client) =
    mqtt_actor.using_tcp("mqtt.beatwaves.net", 1883, 1000)
    |> mqtt.connect_with_id("spoke-test")
    |> mqtt_actor.start_session()

  let updates = mqtt_actor.subscribe_to_updates(client)

  mqtt_actor.connect(client, True, None)
  echo process.receive_forever(updates)

  let assert Ok(_) =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest("zigbee2mqtt/#", mqtt.AtMostOnce),
    ])

  loop(updates)
}

fn loop(updates: Subject(mqtt.Update)) {
  echo process.receive_forever(updates)
  loop(updates)
}
