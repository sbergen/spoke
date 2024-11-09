import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleamqtt/transport.{type ByteChannel, type Receiver}

/// Creates a channel that will send to the given subject,
/// and a subject that receives the receiver passed to start_receive when called.
pub fn new(
  send: Subject(BitArray),
) -> #(ByteChannel, Subject(Receiver(BitArray))) {
  let receiver = process.new_subject()

  let channel =
    transport.Channel(
      send: fn(bytes) {
        Ok(process.send(send, bytes_builder.to_bit_array(bytes)))
      },
      start_receive: fn(subject) { process.send(receiver, subject) },
    )

  #(channel, receiver)
}
