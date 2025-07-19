import argv
import drift/js/channel.{type Channel}
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/option.{None}
import gleam/string
import spoke/mqtt
import spoke/mqtt_js

pub fn main() {
  let usage = "Provide the broker url and topic to subscribe to as arguments"
  case argv.load().arguments {
    [url, topic] -> {
      let client =
        mqtt_js.using_websocket(url)
        |> mqtt.connect_with_id("spoke_js_cli")
        |> mqtt_js.start_session()

      let #(updates, _) = mqtt_js.subscribe_to_updates(client)
      mqtt_js.connect(client, True, None)

      use update <- promise.await(channel.receive(updates, 1000))
      let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
        update

      use sub_result <- promise.await(
        mqtt_js.subscribe(client, [
          mqtt.SubscribeRequest(topic, mqtt.AtLeastOnce),
        ]),
      )
      let assert Ok(_) = sub_result

      print_updates(updates)
    }
    _ -> {
      io.println(usage)
      promise.resolve(Nil)
    }
  }
}

fn print_updates(updates: Channel(a)) -> Promise(Nil) {
  use update <- promise.await(channel.receive_forever(updates))
  io.println_error(string.inspect(update))
  print_updates(updates)
}
