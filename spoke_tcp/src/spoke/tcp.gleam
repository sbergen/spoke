import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}
import gleam/result
import gleam/string
import mug

/// Send, receive, and shutdown functions,
/// as defined in the main spoke package.
pub type TransportChannel =
  #(
    fn(BytesTree) -> Result(Nil, String),
    fn() -> Selector(Result(BitArray, String)),
    fn() -> Nil,
  )

/// Re-definition of what spoke uses for transport channels
/// (simplifies package dependencies).
pub type TransportChannelConnector =
  fn() -> Result(TransportChannel, String)

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

  let selector =
    process.new_selector()
    |> mug.select_tcp_messages(map_tcp_message)

  Ok(
    #(
      send(socket, _),
      fn() {
        mug.receive_next_packet_as_message(socket)
        selector
      },
      fn() {
        // Nothing to do if this fails
        let _ = mug.shutdown(socket)
        Nil
      },
    ),
  )
}

fn send(socket: mug.Socket, data: BytesTree) -> Result(Nil, String) {
  mug.send_builder(socket, data)
  |> map_mug_error("Send error")
}

fn map_tcp_message(msg: mug.TcpMessage) -> Result(BitArray, String) {
  case msg {
    mug.Packet(_, data) -> Ok(data)
    mug.SocketClosed(_) -> Error("Channel closed")
    mug.TcpError(_, e) -> Error("TCP error: " <> string.inspect(e))
  }
}

fn map_mug_error(r: Result(a, e), reason: String) -> Result(a, String) {
  result.map_error(r, fn(e) { reason <> ": " <> string.inspect(e) })
}
