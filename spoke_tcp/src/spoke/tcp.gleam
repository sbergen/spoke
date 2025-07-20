import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/result
import gleam/string
import mug
import spoke/core
import spoke/mqtt_actor.{type TransportChannel, type TransportChannelConnector}

/// Constructs an (unencrypted) TCP connector using the defaults of
/// connecting to port 1883 on the given host.
pub fn connector_with_defaults(host host: String) -> TransportChannelConnector {
  connector(host, 1883, 5000)
}

/// Constructs an (unencrypted) TCP connector.
pub fn connector(
  host host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
) -> TransportChannelConnector {
  fn() { connect(host, port, connect_timeout) }
}

fn connect(
  host: String,
  port: Int,
  connect_timeout: Int,
) -> Result(TransportChannel, String) {
  // TODO: add ip preference
  let options =
    mug.ConnectionOptions(host, port, connect_timeout, mug.Ipv6Preferred)
  use socket <- result.try(
    mug.connect(options) |> map_mug_error("Connect error"),
  )

  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> mug.select_tcp_messages(map_tcp_message)
    |> process.select(subject)

  process.send(subject, core.TransportEstablished)
  mug.receive_next_packet_as_message(socket)

  Ok(mqtt_actor.TransportChannel(
    //
    selector,
    send(socket, _),
    fn() { mug.shutdown(socket) |> map_mug_error("Shutdown error") },
  ))
}

fn send(socket: mug.Socket, data: BytesTree) -> Result(Nil, String) {
  mug.send_builder(socket, data)
  |> map_mug_error("Send error")
}

fn map_tcp_message(msg: mug.TcpMessage) -> core.TransportEvent {
  case msg {
    mug.Packet(socket, data) -> {
      mug.receive_next_packet_as_message(socket)
      core.ReceivedData(data)
    }
    mug.SocketClosed(_) -> core.TransportClosed
    mug.TcpError(_, e) ->
      core.TransportFailed("TCP error: " <> string.inspect(e))
  }
}

fn map_mug_error(r: Result(a, e), reason: String) -> Result(a, String) {
  result.map_error(r, fn(e) { reason <> ": " <> string.inspect(e) })
}
