import gleam/erlang/process.{type Subject}
import spoke/transport.{type Channel, type Receiver}

pub fn new(
  send: Subject(out),
  map_send: fn(s) -> out,
  receivers: Subject(Receiver(r)),
) -> Channel(s, r) {
  transport.Channel(
    send: fn(data) { Ok(process.send(send, map_send(data))) },
    start_receive: fn(receiver) { process.send(receivers, receiver) },
  )
}
