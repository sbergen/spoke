import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleamqtt/internal/utils
import gleamqtt/transport.{type Channel, type ChannelError}
import mug.{type Socket}

pub fn connect(
  host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
  send_timeout send_timeout: Int,
) -> Result(Channel, actor.StartError) {
  let mug_options = mug.ConnectionOptions(host, port, connect_timeout)
  let receive = process.new_subject()

  actor.start_spec(actor.Spec(
    fn() { init(mug_options, receive) },
    mug_options.timeout + 10,
    handle_message,
  ))
  |> result.map(fn(subject) {
    transport.Channel(
      send: fn(bytes) { actor.call(subject, Send(bytes, _), send_timeout) },
      receive: utils.as_selector(receive),
    )
  })
}

type State {
  State(socket: Socket, receive: Subject(Result(BitArray, ChannelError)))
}

type Message {
  Send(data: BytesBuilder, reply_with: Subject(Result(Nil, ChannelError)))
  Received(Result(BitArray, ChannelError))
}

fn init(
  options: mug.ConnectionOptions,
  receive: Subject(Result(BitArray, ChannelError)),
) -> actor.InitResult(State, Message) {
  case mug.connect(options) {
    Ok(socket) -> {
      let selector =
        process.new_selector()
        |> mug.selecting_tcp_messages(map_tcp_message)
      mug.receive_next_packet_as_message(socket)
      actor.Ready(State(socket, receive), selector)
    }
    Error(e) -> actor.Failed(string.inspect(e))
  }
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Received(msg) -> {
      mug.receive_next_packet_as_message(state.socket)
      process.send(state.receive, msg)
    }

    Send(data, reply_to) -> {
      let reply =
        mug.send_builder(state.socket, data)
        |> map_mug_error(transport.SendFailed)
      process.send(reply_to, reply)
    }
  }

  actor.continue(state)
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
) -> Result(a, ChannelError) {
  result.map_error(r, fn(e) { ctor(string.inspect(e)) })
}
