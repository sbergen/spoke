//// Tests that require a MQTT broker to be running on localhost

import gleam/dynamic.{type Dynamic}
import gleam/erlang
import gleam/erlang/process
import gleam/io
import gleam/result
import gleam/string
import gleeunit/should
import spoke

pub fn main() -> Int {
  io.println("Running integration tests:")
  io.println("--------------------------")
  let failures =
    0
    |> run_test("Subscribe & publish, QoS 0", subscribe_and_publish_qos0)
    |> run_test("Receive after reconnect, QoS 1", fn() {
      receive_after_reconnect(spoke.AtLeastOnce)
    })
    |> run_test("Receive after reconnect, QoS 2", fn() {
      receive_after_reconnect(spoke.ExactlyOnce)
    })
    |> run_test("Will is published when client dies", will_disconnect)

  io.println("--------------------------")
  case failures {
    0 -> io.println("All tests passed!")
    _ -> io.println(string.inspect(failures) <> " tests failed :(")
  }

  failures
}

fn subscribe_and_publish_qos0() -> Nil {
  let client =
    spoke.default_tcp_options("localhost")
    |> spoke.connect_with_id("subscribe_and_publish")
    |> spoke.start_session
  let updates = spoke.updates(client)

  connect_and_wait(client, True)

  let topic = "subscribe_and_publish"
  let assert Ok(_) =
    spoke.subscribe(client, [spoke.SubscribeRequest(topic, spoke.AtLeastOnce)])
    as "Should subscribe successfully"

  let message =
    spoke.PublishData(
      topic,
      <<"Hello from spoke!">>,
      spoke.AtMostOnce,
      retain: False,
    )
  spoke.publish(client, message)

  let assert Ok(spoke.ReceivedMessage(received_topic, payload, retained)) =
    process.receive(updates, 1000)

  disconnect_and_wait(client)

  received_topic |> should.equal(topic)
  payload |> should.equal(<<"Hello from spoke!">>)
  retained |> should.equal(False)
}

fn receive_after_reconnect(qos: spoke.QoS) -> Nil {
  let topic = "qos_topic"

  let receiver_client =
    spoke.default_tcp_options("localhost")
    |> spoke.connect_with_id("qos_receiver")
    |> spoke.start_session

  // Connect and subscribe
  flush_server_state(receiver_client)
  connect_and_wait(receiver_client, False)
  let assert Ok(_) =
    spoke.subscribe(receiver_client, [spoke.SubscribeRequest(topic, qos)])
    as "Subscribe should succeed"

  disconnect_and_wait(receiver_client)

  // Send the message

  let sender_client =
    spoke.default_tcp_options("localhost")
    |> spoke.connect_with_id("qos_sender")
    |> spoke.start_session
  connect_and_wait(sender_client, True)

  spoke.publish(
    sender_client,
    spoke.PublishData(topic, <<"persisted msg">>, qos, False),
  )
  disconnect_and_wait(sender_client)

  // Now reconnect without cleaning session: the message should be received
  connect_and_wait(receiver_client, False)

  let updates = spoke.updates(receiver_client)
  let assert Ok(spoke.ReceivedMessage("qos_topic", <<"persisted msg">>, False)) =
    process.receive(updates, 1000)
    as "QoS > 0 message should be received when reconnecting without cleaning session"

  disconnect_and_wait(receiver_client)
}

fn will_disconnect() -> Nil {
  let topic = "will_topic"

  let client =
    spoke.default_tcp_options("localhost")
    |> spoke.connect_with_id("will_receiver")
    |> spoke.start_session
  connect_and_wait(client, True)
  let assert Ok(_) =
    spoke.subscribe(client, [spoke.SubscribeRequest(topic, spoke.AtMostOnce)])

  process.start(linked: False, running: fn() {
    let client =
      spoke.default_tcp_options("localhost")
      |> spoke.connect_with_id("will_sender")
      |> spoke.start_session
    let will =
      spoke.PublishData(topic, <<"will message">>, spoke.AtLeastOnce, False)
    spoke.connect_with_will(client, True, will)

    // Subscribe with an invalid topic to get rejected
    let _ =
      spoke.subscribe(client, [spoke.SubscribeRequest("/#/", spoke.AtLeastOnce)])
    process.sleep(100)
  })

  let assert Ok(spoke.ReceivedMessage(_, <<"will message">>, False)) =
    process.receive(spoke.updates(client), 1000)
    as "Expected to receive will message"

  Nil
}

fn flush_server_state(client: spoke.Client) -> Nil {
  // Connect with clean session set to true, then disconnect
  connect_and_wait(client, True)
  disconnect_and_wait(client)
}

fn connect_and_wait(client: spoke.Client, clean_session: Bool) -> Nil {
  let updates = spoke.updates(client)
  spoke.connect(client, clean_session)
  let assert Ok(spoke.ConnectionStateChanged(spoke.ConnectAccepted(_))) =
    process.receive(updates, 1000)
    as "Should connect successfully"
  Nil
}

fn disconnect_and_wait(client: spoke.Client) -> Nil {
  let updates = spoke.updates(client)
  spoke.disconnect(client)
  let assert Ok(spoke.ConnectionStateChanged(spoke.Disconnected)) =
    process.receive(updates, 1000)
    as "Should disconnect successfully"
  Nil
}

fn run_test(failures: Int, description: String, workload: fn() -> Nil) -> Int {
  io.print("* " <> description)

  case erlang.rescue(workload) |> result.map_error(extract_reason) {
    Ok(Nil) -> {
      io.println(": ✓")
      failures
    }
    Error(reason) -> {
      io.println(": ✘ " <> string.inspect(reason))
      failures + 1
    }
  }
}

fn extract_reason(crash: erlang.Crash) -> Dynamic {
  case crash {
    erlang.Errored(reason) -> reason
    erlang.Exited(reason) -> reason
    erlang.Thrown(reason) -> reason
  }
}
