import drift/js/channel
import gleam/javascript/promise.{type Promise}
import gleam/option.{None}
import gleeunit
import spoke/mqtt.{ConnectAccepted, ConnectionStateChanged}
import spoke/mqtt_js

pub fn main() -> Nil {
  gleeunit.main()
}
//pub fn main() -> Promise(Nil) {
//   let client =
//     mqtt_js.using_websocket("mqtt.beatwaves.net", 8083, 1000)
//     |> mqtt.connect_with_id("spoke-test")
//     |> mqtt_js.start_session()

//   let #(updates, _) = mqtt_js.subscribe_to_updates(client)
//   mqtt_js.connect(client, True, None)

//   use update <- promise.await(channel.receive(updates))
//   let assert Ok(ConnectionStateChanged(ConnectAccepted(_))) = update

//   use sub_result <- promise.await(
//     mqtt_js.subscribe(client, [
//       mqtt.SubscribeRequest("zigbee2mqtt/#", mqtt.AtMostOnce),
//     ]),
//   )

//   let assert Ok(_) = echo sub_result
//   loop(updates)
// }

// fn loop(channel: channel.Channel(mqtt.Update)) -> Promise(Nil) {
//   use update <- promise.await(channel.receive(channel))
//   echo update
//   loop(channel)
// }
