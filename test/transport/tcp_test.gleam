import gleam/bytes_builder
import gleam/erlang/process
import gleeunit/should
import spoke/internal/transport/tcp
import transport/echo_server

pub fn send_receive_and_shutdown_test() {
  let shutdowns = process.new_subject()
  let port = echo_server.start(fn() { process.send(shutdowns, Nil) })
  let assert Ok(channel) =
    tcp.connect(
      "localhost",
      port: port,
      connect_timeout: 100,
      send_timeout: 100,
    )

  let receiver = process.new_subject()
  channel.start_receive(receiver)

  let assert Ok(_) = channel.send(bytes_builder.from_string("let's go!"))
  let assert Ok(Ok(bytes)) = process.receive(receiver, 100)
  bytes |> should.equal(<<"let's go!">>)

  let assert Ok(_) = channel.send(bytes_builder.from_string("and again!"))
  let assert Ok(Ok(bytes)) = process.receive(receiver, 100)
  bytes |> should.equal(<<"and again!">>)

  let assert Error(_) = process.receive(shutdowns, 0)
  channel.shutdown()
  let assert Ok(_) = process.receive(shutdowns, 10)
}
