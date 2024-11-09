import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/io
import gleamqtt.{type Update}
import gleamqtt/internal/client_impl.{type ClientImpl}
import gleamqtt/internal/packet/incoming
import gleamqtt/internal/packet/outgoing
import gleamqtt/transport.{type Receiver}
import gleeunit/should
import transport/fake_channel

const id = "client-id"

const keep_alive = 60

pub fn connect_success_test() {
  let #(_client, sent_packets, connections, updates) = set_up()

  // Connect request
  let assert Ok(server_out) = process.receive(connections, 10)
  let assert Ok(request) = process.receive(sent_packets, 10)
  request |> should.equal(outgoing.Connect(id, keep_alive))

  // Connect response
  process.send(
    server_out,
    Ok(incoming.ConnAck(False, gleamqtt.ConnectionAccepted)),
  )
  let assert Ok(gleamqtt.ConnectFinished(gleamqtt.ConnectionAccepted, False)) =
    process.receive(updates, 10)
}

fn set_up() -> #(
  ClientImpl,
  Subject(outgoing.Packet),
  Subject(Receiver(incoming.Packet)),
  Subject(Update),
) {
  let options = gleamqtt.ConnectOptions(id, keep_alive)

  let send_to = process.new_subject()
  let connections = process.new_subject()
  let client_receives = process.new_subject()

  let connect = fn() {
    fake_channel.new(send_to, function.identity, connections)
  }
  let client = client_impl.run(options, connect, client_receives)
  #(client, send_to, connections, client_receives)
}
