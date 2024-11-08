import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamqtt.{type QoS}
import gleamqtt/internal/transport/tcp
import gleamqtt/transport.{type Channel, type ChannelOptions}

pub type ReceivedMessage {
  ReceivedMessage(topic: String, payload: BitArray, retained: Bool)
}

pub type Subscription {
  Subscription(topic_filter: String, qos: QoS)
}

pub type SubscribeRequest {
  SubscribeRequest(filter: String, qos: QoS)
}

pub opaque type Client

pub fn connect(options: ChannelOptions) -> Result(Channel, actor.StartError) {
  case options {
    transport.TcpOptions(host, port, connect_timeout, send_timeout) ->
      tcp.connect(host, port, connect_timeout, send_timeout)
  }
}

pub fn start(
  channel: Channel,
  receive: Subject(ReceivedMessage),
) -> Result(Client, actor.StartError) {
  todo
}

pub fn subscribe(
  client: Client,
  requests: List(SubscribeRequest),
) -> List(Result(Subscription, Nil)) {
  todo
}
