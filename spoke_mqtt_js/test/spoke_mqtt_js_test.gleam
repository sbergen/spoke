import gleam/javascript/promise
import gleam/option.{None}
import spoke/mqtt
import spoke/mqtt_js

pub fn main() -> promise.Promise(Nil) {
  //gleeunit.main()

  let client =
    mqtt_js.using_websocket("mqtt.beatwaves.net", 8083, 1000)
    |> mqtt.connect_with_id("spoke-test")
    |> mqtt_js.start_session()

  mqtt_js.subscribe_to_updates(client, fn(update) {
    echo update
    Nil
  })

  // IDK how to wait for connected :/
  mqtt_js.connect(client, True, None)
  use _ <- promise.await(promise.wait(1000))

  use sub_result <- promise.await(
    mqtt_js.subscribe(client, [
      mqtt.SubscribeRequest("zigbee2mqtt/#", mqtt.AtMostOnce),
    ]),
  )

  let assert Ok(_) = echo sub_result

  use _ <- promise.map(promise.wait(100_000))
  Nil
  // let assert Ok(_) =
  //   
}
