import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/otp/task
import gleam/set.{type Set}
import gleam/string
import spoke.{type Update, PublishData}
import spoke/tcp

const total_messages = 100_000

const tasks = 100

/// Runs a stress test on a MQTT broker running on localhost.
/// Note that this is not part of the default test suite,
/// as it requires a running broker.
pub fn main() {
  let client_id = "spoke"

  io.println("Connecting & subscribing..")
  let client =
    tcp.connector_with_defaults("localhost")
    |> spoke.connect_with_id(client_id)
    |> spoke.start_session

  spoke.connect(client, True)

  let updates = spoke.updates(client)
  let assert Ok(spoke.ConnectionStateChanged(spoke.ConnectAccepted(_))) =
    process.receive(updates, 100)

  let assert Ok(_) =
    spoke.subscribe(client, [spoke.SubscribeRequest("#", spoke.AtLeastOnce)])

  let messages_per_task = total_messages / tasks
  list.range(1, tasks)
  |> list.each(fn(i) {
    use <- task.async()
    let index = string.inspect(i)
    let message =
      PublishData("topic" <> index, <<>>, spoke.AtLeastOnce, retain: False)
    list.range(1, messages_per_task)
    |> list.each(fn(msg_index) {
      let payload = "Hello: " <> string.inspect(msg_index)
      spoke.publish(client, PublishData(..message, payload: <<payload:utf8>>))
      process.sleep(1)
    })
  })

  io.println("Receiving messages...")
  let all_data = receive(set.new(), updates)

  io.println(
    "Done receiving " <> string.inspect(set.size(all_data)) <> " messages!",
  )

  spoke.disconnect(client)
  let assert Ok(spoke.ConnectionStateChanged(spoke.Disconnected)) =
    process.receive(updates, 10)
}

fn receive(
  data: Set(spoke.Update),
  updates: Subject(Update),
) -> Set(spoke.Update) {
  case set.size(data) == total_messages {
    True -> data
    False -> {
      let assert Ok(update) = process.receive(updates, 500)
      let assert spoke.ReceivedMessage(..) = update
      receive(set.insert(data, update), updates)
    }
  }
}
