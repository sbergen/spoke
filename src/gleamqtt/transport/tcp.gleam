import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleamqtt/transport.{
  type Channel, type ChannelError, type ChannelOptions, type IncomingData,
}
import mug.{type Socket}

/// Connection options for a TCP transport channel
pub type ConnectionOptions {
  ConnectionOptions(host: String, port: Int, timeout: Int)
}

pub fn connect(
  connect_options: ConnectionOptions,
  options: ChannelOptions,
) -> Result(Channel, actor.StartError) {
  let mug_options =
    mug.ConnectionOptions(
      connect_options.host,
      connect_options.port,
      connect_options.timeout,
    )

  let receive = process.new_subject()

  actor.start_spec(actor.Spec(
    fn() { init(mug_options, receive) },
    mug_options.timeout + 10,
    handle_message,
  ))
  |> result.map(fn(subject) {
    transport.Channel(
      send: fn(bytes) {
        actor.call(subject, Send(bytes, _), options.send_timeout)
      },
      receive: receive,
    )
  })
}

type State {
  State(socket: Socket, receive: Subject(IncomingData))
}

type Message {
  Send(data: BytesBuilder, reply_with: Subject(Result(Nil, ChannelError)))
  Received(IncomingData)
}

fn init(
  options: mug.ConnectionOptions,
  receive: Subject(IncomingData),
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
    mug.Packet(_, data) -> transport.IncomingData(data)
    mug.SocketClosed(_) -> transport.ChannelClosed
    mug.TcpError(_, e) ->
      transport.ChannelError(transport.TransportError(string.inspect(e)))
  })
}

fn map_mug_error(
  r: Result(a, mug.Error),
  ctor: fn(String) -> ChannelError,
) -> Result(a, ChannelError) {
  result.map_error(r, fn(e) { ctor(string.inspect(e)) })
}
