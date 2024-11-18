import gleam/erlang/process.{type Subject}
import gleam/otp/task
import spoke.{type Client}
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/internal/transport

pub const client_id = "client-id"

pub fn simulate_server_response(
  receives: Subject(Subject(incoming.Packet)),
  packet: incoming.Packet,
) -> Nil {
  let assert Ok(receiver) = process.receive(receives, 10)
  process.send(receiver, packet)
}

pub fn set_up_connected(
  keep_alive keep_alive: Int,
  server_timeout server_timeout: Int,
) -> #(
  Client,
  Subject(outgoing.Packet),
  Subject(Subject(incoming.Packet)),
  Subject(Nil),
  Subject(spoke.Update),
) {
  let #(client, sent_packets, receives, disconnects, updates) =
    set_up_disconnected(keep_alive, server_timeout)
  let connect_task = task.async(fn() { spoke.connect(client, 10) })

  let assert Ok(outgoing.Connect(_, _)) = process.receive(sent_packets, 10)
  simulate_server_response(receives, incoming.ConnAck(Ok(False)))

  let assert Ok(Ok(_)) = task.try_await(connect_task, 10)
  #(client, sent_packets, receives, disconnects, updates)
}

pub fn set_up_disconnected(
  keep_alive keep_alive: Int,
  server_timeout server_timeout: Int,
) -> #(
  Client,
  Subject(outgoing.Packet),
  Subject(Subject(incoming.Packet)),
  Subject(Nil),
  Subject(spoke.Update),
) {
  let outgoing = process.new_subject()
  let receives = process.new_subject()
  let disconnects = process.new_subject()
  let connect = fn() {
    Ok(transport.Channel(
      send: fn(packet) {
        process.send(outgoing, packet)
        Ok(Nil)
      },
      selecting_next: fn(state) {
        // We don't test chunking in these tests, should write them separately
        let assert <<>> = state

        // This subject needs to be created by the client process
        let incoming = process.new_subject()
        process.send(receives, incoming)

        process.new_selector()
        |> process.selecting(incoming, fn(packet) { #(<<>>, Ok([packet])) })
      },
      shutdown: fn() { process.send(disconnects, Nil) },
    ))
  }

  let updates = process.new_subject()
  let client =
    spoke.run(client_id, keep_alive, server_timeout, connect, updates)
  #(client, outgoing, receives, disconnects, updates)
}
