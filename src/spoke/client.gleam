import gleam/erlang/process.{type Subject}
import spoke.{
  type ConnectError, type ConnectOptions, type PublishData, type PublishError,
  type SubscribeError, type SubscribeRequest, type Subscription, type Update,
}
import spoke/internal/client_impl.{type ClientImpl}
import spoke/internal/transport/channel.{type EncodedChannel}
import spoke/internal/transport/tcp
import spoke/transport.{type TransportOptions}

pub opaque type Client {
  Client(impl: ClientImpl)
}

/// Starts a new MQTT client with the given options.
/// The connection will be automatically established.
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

pub fn connect(
  client: Client,
  timeout timeout: Int,
) -> Result(Bool, ConnectError) {
  client_impl.connect(client.impl, timeout)
}

pub fn subscribe(
  client: Client,
  requests: List(SubscribeRequest),
  timeout: Int,
) -> Result(List(Subscription), SubscribeError) {
  client_impl.subscribe(client.impl, requests, timeout)
}

pub fn publish(
  client: Client,
  data: PublishData,
  timeout: Int,
) -> Result(Nil, PublishError) {
  client_impl.publish(client.impl, data, timeout)
}

fn create_channel(options: TransportOptions) -> EncodedChannel {
  let assert Ok(raw_channel) = case options {
    transport.TcpOptions(host, port, connect_timeout, send_timeout) ->
      tcp.connect(host, port, connect_timeout, send_timeout)
  }
  channel.as_encoded(raw_channel)
}
