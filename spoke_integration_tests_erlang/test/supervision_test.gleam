import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import spoke/mqtt
import spoke/mqtt_actor
import spoke/tcp
import temporary

const connected_topic = "connected"

const echo_topic = "echos"

// Set up a supervision tree with both publishes and subscribes happening
// to a named client.
// Ensure messages can be received and sent both before and after the
// client has been restarted.
pub fn supervision_test() {
  use temp_file <- temporary.create(temporary.file())
  let storage = mqtt_actor.persist_to_ets(temp_file)

  let client_name = process.new_name("mqtt_client")
  let connector_name = process.new_name("mqtt_connector")
  let consumer_name = process.new_name("mqtt_consumer")

  let connector_subject = process.named_subject(connector_name)
  let consumer_subject = process.named_subject(consumer_name)

  let #(builder, client) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("supervision_client")
    |> mqtt_actor.build()
    |> mqtt_actor.using_storage(storage)
    |> mqtt_actor.with_extra_init(process.send(connector_subject, _))
    |> mqtt_actor.named(client_name)

  // Start the listening client, wait for subscribed
  let test_progress = process.new_subject()
  wait_for_start_and_restart(client_name, test_progress)
  let assert Ok(_) = process.receive(test_progress, 100)

  // Start the supervision tree
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(fn() {
        start_connector(connector_name, [consumer_subject])
      }),
    )
    |> static_supervisor.add(mqtt_actor.supervised(builder, 100))
    |> static_supervisor.add(
      supervision.worker(fn() { start_consumer(consumer_name, client) }),
    )
    |> static_supervisor.start

  // Wait for the the full roundtrip of messages in the listening client,
  // triggered by the start and restart.
  let assert Ok(_) = process.receive(test_progress, 100)

  process.send_exit(supervisor.pid)
}

// When a new client is spawned, connect and hook up consumers
fn start_connector(
  name: process.Name(mqtt_actor.Client),
  consumers: List(process.Subject(mqtt.Update)),
) -> Result(actor.Started(process.Subject(mqtt_actor.Client)), actor.StartError) {
  actor.new(Nil)
  |> actor.named(name)
  |> actor.on_message(fn(_, client) {
    // (re)subscribe consumers to updates
    list.each(consumers, mqtt_actor.subscribe_to_updates(client, _))

    // Temporarily listen to connection status
    let updates = process.new_subject()
    let subscription = mqtt_actor.subscribe_to_updates(client, updates)

    // Connect and wait for connection
    mqtt_actor.connect(client, False, None)
    let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(
      session_present,
    ))) = process.receive(updates, 1000)
    mqtt_actor.unsubscribe_from_updates(client, subscription)

    // Resubscribe if session not present
    let assert Ok(_) = case session_present {
      mqtt.SessionNotPresent -> {
        mqtt_actor.subscribe(client, [
          mqtt.SubscribeRequest(connected_topic, mqtt.ExactlyOnce),
        ])
      }
      mqtt.SessionPresent -> Ok([])
    }

    // Send message to connected topic
    mqtt_actor.publish(
      client,
      mqtt.PublishData(connected_topic, <<"Hello!">>, mqtt.ExactlyOnce, False),
    )

    // Additionally, in a real situation we should reconnect when disconnected,
    // but this is already complex enough for this test :D

    actor.continue(Nil)
  })
  |> actor.start()
}

// Echoes messages to echo_topic
fn start_consumer(
  name: process.Name(mqtt.Update),
  client: mqtt_actor.Client,
) -> Result(actor.Started(process.Subject(mqtt.Update)), actor.StartError) {
  actor.new(Nil)
  |> actor.named(name)
  |> actor.on_message(fn(_, update) {
    case update {
      mqtt.ReceivedMessage(_, payload, _) -> {
        mqtt_actor.publish(
          client,
          mqtt.PublishData(echo_topic, payload, mqtt.ExactlyOnce, False),
        )
      }
      _ -> Nil
    }
    actor.continue(Nil)
  })
  |> actor.start()
}

fn wait_for_start_and_restart(
  client_name: process.Name(a),
  progress: process.Subject(Nil),
) -> process.Pid {
  use <- process.spawn()

  let assert Ok(started) =
    tcp.connector_with_defaults("localhost")
    |> mqtt.connect_with_id("supervision_observer")
    |> mqtt_actor.build()
    |> mqtt_actor.start(100)
  let client = started.data

  let updates = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates)
  mqtt_actor.connect(client, True, None)

  let assert Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) =
    process.receive(updates, 1000)
  let assert Ok(_) =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(echo_topic, mqtt.ExactlyOnce),
    ])

  // Notify subscribed
  process.send(progress, Nil)

  // Wait for start, kill client, wait for restart
  let assert Ok(mqtt.ReceivedMessage(_, _, _)) = process.receive(updates, 1000)
  let assert Ok(client_pid) = process.named(client_name)
  process.kill(client_pid)
  let assert Ok(mqtt.ReceivedMessage(_, _, _)) = process.receive(updates, 1000)

  // Notify completed
  process.send(progress, Nil)
}
