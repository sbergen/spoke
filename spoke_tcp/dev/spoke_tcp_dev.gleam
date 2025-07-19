import argv
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/string
import spoke/mqtt
import spoke/mqtt_actor
import spoke/tcp

pub fn main() {
  let usage =
    "Provide the broker host, port, and topic to subscribe to as arguments"
  case argv.load().arguments {
    [host, port, topic] -> {
      case int.parse(port) {
        Error(_) -> {
          io.println("Invalid port: " <> port)
          io.println(usage)
        }
        Ok(port) -> {
          let assert Ok(client) =
            tcp.connector(host, port, 1000)
            |> mqtt.connect_with_id("spoke_tcp_cli")
            |> mqtt.keep_alive_seconds(1)
            |> mqtt_actor.start_session(None)

          let updates = process.new_subject()
          mqtt_actor.subscribe_to_updates(client, updates)
          mqtt_actor.connect(client, True, None)

          let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
            process.receive(updates, 1000)

          let assert Ok(_) =
            mqtt_actor.subscribe(client, [
              mqtt.SubscribeRequest(topic, mqtt.ExactlyOnce),
            ])

          print_updates(updates)
        }
      }
    }
    _ -> io.println(usage)
  }
}

fn print_updates(updates: process.Subject(a)) -> Nil {
  io.println(string.inspect(process.receive_forever(updates)))
  print_updates(updates)
}
