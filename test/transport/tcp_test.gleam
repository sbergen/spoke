import gleam/bytes_builder
import gleam/erlang/process
import gleamqtt/internal/transport/tcp
import gleeunit/should
import transport/echo_server

pub fn send_and_receive_test() {
  let port = echo_server.start()
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
}
