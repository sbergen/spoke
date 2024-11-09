import gleam/erlang/process.{type Subject}
import gleamqtt.{type ConnectOptions, type Update}
import gleamqtt/internal/client_impl.{type ClientImpl}
import gleamqtt/internal/transport/channel.{type EncodedChannel}
import gleamqtt/internal/transport/tcp
import gleamqtt/transport.{type TransportOptions}

pub opaque type Client {
  Client(impl: ClientImpl)
}

pub fn start(
  connect_opts: ConnectOptions,
  transport_opts: TransportOptions,
  updates: Subject(Update),
) -> Client {
  Client(client_impl.run(
    connect_opts,
    fn() { create_channel(transport_opts) },
    updates,
  ))
}

fn create_channel(options: TransportOptions) -> EncodedChannel {
  let assert Ok(raw_channel) = case options {
    transport.TcpOptions(host, port, connect_timeout, send_timeout) ->
      tcp.connect(host, port, connect_timeout, send_timeout)
  }
  channel.as_encoded(raw_channel)
}
