import gleam/bytes_builder
import gleam/erlang/process
import gleamqtt/transport
import gleamqtt/transport/tcp
import gleeunit/should
import transport/echo_server

pub fn send_and_receive_test() {
  let port = echo_server.start()
  let connect_opts = tcp.ConnectionOptions("localhost", port, 100)
  let opts = transport.ChannelOptions(100)
  let assert Ok(channel) = tcp.connect(connect_opts, opts)

  let assert Ok(_) = channel.send(bytes_builder.from_string("let's go!"))
  let assert Ok(transport.IncomingData(bytes)) =
    process.receive(channel.receive, 100)
  bytes |> should.equal(<<"let's go!">>)

  let assert Ok(_) = channel.send(bytes_builder.from_string("and again!"))
  let assert Ok(transport.IncomingData(bytes)) =
    process.receive(channel.receive, 100)
  bytes |> should.equal(<<"and again!">>)
}
