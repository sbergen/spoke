import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mug.{type Socket}
import spoke/transport.{
  type ByteChannel, type ChannelError, type ChannelResult, type Receiver,
}

pub fn connect(
  host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
  send_timeout send_timeout: Int,
) -> Result(ByteChannel, actor.StartError) {
  let mug_options = mug.ConnectionOptions(host, port, connect_timeout)

  actor.start_spec(actor.Spec(
    fn() { init(mug_options) },
    mug_options.timeout + 100,
    handle_message,
  ))
  |> result.map(fn(subject) {
    transport.Channel(
      send: fn(bytes) { actor.call(subject, Send(bytes, _), send_timeout) },
      start_receive: fn(receiver) { actor.send(subject, SetReceiver(receiver)) },
    )
  })
}

type State {
  State(socket: Socket, receiver: Option(Receiver(BitArray)))
}

type Message {
  SetReceiver(Receiver(BitArray))
  Send(data: BytesBuilder, reply_with: Receiver(Nil))
  Received(ChannelResult(BitArray))
}

fn init(options: mug.ConnectionOptions) -> actor.InitResult(State, Message) {
  case mug.connect(options) {
    Ok(socket) -> {
      let selector =
        process.new_selector()
        |> mug.selecting_tcp_messages(map_tcp_message)
      actor.Ready(State(socket, None), selector)
    }
    Error(e) -> actor.Failed(string.inspect(e))
  }
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    SetReceiver(receiver) -> {
      mug.receive_next_packet_as_message(state.socket)
      actor.continue(State(..state, receiver: Some(receiver)))
    }

    Received(msg) -> {
      // We shouldn't be receiving any packets before the receiver is set
      let assert Some(receiver) = state.receiver
      mug.receive_next_packet_as_message(state.socket)
      process.send(receiver, msg)
      actor.continue(state)
    }

    Send(data, reply_to) -> {
      let reply =
        mug.send_builder(state.socket, data)
        |> map_mug_error(transport.SendFailed)
      process.send(reply_to, reply)
      actor.continue(state)
    }
  }
}

fn map_tcp_message(msg: mug.TcpMessage) -> Message {
  Received(case msg {
    mug.Packet(_, data) -> Ok(data)
    mug.SocketClosed(_) -> Error(transport.ChannelClosed)
    mug.TcpError(_, e) -> Error(transport.TransportError(string.inspect(e)))
  })
}

fn map_mug_error(
  r: Result(a, mug.Error),
  ctor: fn(String) -> ChannelError,
) -> ChannelResult(a) {
  result.map_error(r, fn(e) { ctor(string.inspect(e)) })
}
