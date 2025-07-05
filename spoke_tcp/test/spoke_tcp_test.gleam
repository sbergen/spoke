import echo_server
import gleam/bytes_tree
import gleam/erlang/process.{type Selector}
import gleeunit
import spoke/core
import spoke/tcp

pub fn main() {
  gleeunit.main()
}

pub fn send_receive_and_shutdown_test() {
  let shutdowns = process.new_subject()
  let port = echo_server.start(fn() { process.send(shutdowns, Nil) })
  let assert Ok(channel) =
    tcp.connector("localhost", port: port, connect_timeout: 100)()

  let assert Ok(_) = channel.send(bytes_tree.from_string("let's go!"))
  assert receive_next(channel.events) == Ok(core.TransportEstablished)
  assert receive_next(channel.events) == Ok(core.ReceivedData(<<"let's go!">>))

  let assert Ok(_) = channel.send(bytes_tree.from_string("and again!"))
  assert receive_next(channel.events) == Ok(core.ReceivedData(<<"and again!">>))

  let assert Error(_) = process.receive(shutdowns, 0)
  let assert Ok(_) = channel.close()
  assert receive_next(channel.events) == Ok(core.TransportClosed)
  let assert Ok(_) = process.receive(shutdowns, 10)
}

fn receive_next(
  next: Selector(core.TransportEvent),
) -> Result(core.TransportEvent, Nil) {
  process.selector_receive(next, 100)
}
