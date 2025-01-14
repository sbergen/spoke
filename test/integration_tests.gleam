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
    |> run_test("subscribe & publish", subscribe_and_publish)

  io.println("--------------------------")
  case failures {
    0 -> io.println("All tests passed!")
    _ -> io.println(string.inspect(failures) <> " tests failed :(")
  }

  failures
}

fn subscribe_and_publish() -> Nil {
  let connect_opts =
    spoke.ConnectOptions(
      "subscribe_and_publish",
      keep_alive_seconds: 1,
      server_timeout_ms: 100,
    )
  let transport_opts = spoke.TcpOptions("localhost", 1883, connect_timeout: 100)
  let client = spoke.start(connect_opts, transport_opts)
  let updates = spoke.updates(client)

  spoke.connect(client, True)
  let assert Ok(spoke.ConnectionStateChanged(spoke.ConnectAccepted(_))) =
    process.receive(updates, 1000)
    as "Connection should be accepted"

  let topic = "subscribe_and_publish"
  let assert Ok(_) =
    spoke.subscribe(client, [spoke.SubscribeRequest(topic, spoke.AtLeastOnce)])
    as "Should connect successfully"

  let message =
    spoke.PublishData(
      topic,
      <<"Hello from spoke!">>,
      spoke.AtLeastOnce,
      retain: False,
    )
  spoke.publish(client, message)

  let assert Ok(spoke.ReceivedMessage(received_topic, payload, retained)) =
    process.receive(updates, 1000)

  received_topic |> should.equal(topic)
  payload |> should.equal(<<"Hello from spoke!">>)
  retained |> should.equal(False)
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
