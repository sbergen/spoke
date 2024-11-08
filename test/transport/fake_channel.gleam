import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleamqtt/transport.{type Channel}

/// Creates a channel that wraps the given subjects
pub fn success(send: Subject(BitArray), receive: Subject(BitArray)) -> Channel {
  transport.Channel(
    send: fn(bytes) {
      Ok(process.send(send, bytes_builder.to_bit_array(bytes)))
    },
    receive: process.new_selector()
      |> process.selecting(receive, fn(data) { transport.IncomingData(data) }),
  )
}
