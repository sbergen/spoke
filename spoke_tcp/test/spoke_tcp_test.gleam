import echo_server
import gleam/bytes_tree
import gleam/erlang/process.{type Selector}
import gleeunit
import gleeunit/should
import spoke/tcp

pub fn main() {
  gleeunit.main()
}

pub fn send_receive_and_shutdown_test() {
  let shutdowns = process.new_subject()
  let port = echo_server.start(fn() { process.send(shutdowns, Nil) })
  let assert Ok(#(send, receive, shutdown)) =
    tcp.connector("localhost", port: port, connect_timeout: 100)()

  let assert Ok(_) = send(bytes_tree.from_string("let's go!"))
  receive_next(receive()) |> should.equal(<<"let's go!">>)

  let assert Ok(_) = send(bytes_tree.from_string("and again!"))
  receive_next(receive()) |> should.equal(<<"and again!">>)

  let assert Error(_) = process.receive(shutdowns, 0)
  shutdown()
  let assert Ok(_) = process.receive(shutdowns, 10)
}

fn receive_next(next: Selector(Result(BitArray, String))) -> BitArray {
  let assert Ok(Ok(bytes)) = process.select(next, 100)
  bytes
}
