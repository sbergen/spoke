import gleam/bytes_builder
import gleam/erlang/process
import gleeunit/should
import spoke/internal/transport/tcp
import spoke/transport.{type ByteChannel}
import transport/echo_server

pub fn send_receive_and_shutdown_test() {
  let shutdowns = process.new_subject()
  let port = echo_server.start(fn() { process.send(shutdowns, Nil) })
  let assert Ok(channel) =
    tcp.connect("localhost", port: port, connect_timeout: 100)

  let assert Ok(_) = channel.send(bytes_builder.from_string("let's go!"))
  receive_next(channel) |> should.equal(<<"let's go!">>)

  let assert Ok(_) = channel.send(bytes_builder.from_string("and again!"))
  receive_next(channel) |> should.equal(<<"and again!">>)

  let assert Error(_) = process.receive(shutdowns, 0)
  channel.shutdown()
  let assert Ok(_) = process.receive(shutdowns, 10)
}

fn receive_next(channel: ByteChannel) -> BitArray {
  let assert Ok(#(Nil, Ok(bytes))) =
    process.select(channel.selecting_next(Nil), 100)
  bytes
}
