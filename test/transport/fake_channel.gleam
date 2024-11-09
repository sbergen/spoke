import gleam/erlang/process.{type Subject}
import gleamqtt/transport.{type Channel, type Receiver}

/// Creates a channel that will send to the given subject,
/// and a subject that receives the receiver passed to start_receive when called.
pub fn new(
  send: Subject(out),
  map_send: fn(s) -> out,
) -> #(Channel(s, r), Subject(Receiver(r))) {
  let receiver = process.new_subject()

  let channel =
    transport.Channel(
      send: fn(data) { Ok(process.send(send, map_send(data))) },
      start_receive: fn(subject) { process.send(receiver, subject) },
    )

  #(channel, receiver)
}
