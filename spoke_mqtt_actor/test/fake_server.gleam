import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import spoke/core.{type TransportEvent}
import spoke/mqtt_actor.{type TransportChannelConnector, TransportChannel}
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub opaque type FakeTransportChannel {
  FakeTransportChannel(
    connections: Subject(Subject(TransportEvent)),
    incoming: Option(Subject(TransportEvent)),
    outgoing: Subject(BytesTree),
  )
}

pub fn new() -> #(TransportChannelConnector, FakeTransportChannel) {
  let outgoing_data = process.new_subject()
  let conncetions = process.new_subject()

  let connector = fn() {
    let incoming_data = process.new_subject()
    let selector = process.new_selector() |> process.select(incoming_data)
    process.send(conncetions, incoming_data)

    Ok(
      TransportChannel(
        events: selector,
        send: fn(data) {
          process.send(outgoing_data, data)
          Ok(Nil)
        },
        close: fn() { Ok(Nil) },
      ),
    )
  }

  let channel = FakeTransportChannel(conncetions, None, outgoing_data)
  #(connector, channel)
}

pub fn connected(channel) -> FakeTransportChannel {
  send_event(channel, core.TransportEstablished)
}

pub fn send(
  channel: FakeTransportChannel,
  packet: server_out.Packet,
) -> FakeTransportChannel {
  let data = bytes_tree.to_bit_array(server_out.encode_packet(packet))
  send_event(channel, core.ReceivedData(data))
}

fn send_event(
  channel: FakeTransportChannel,
  event: TransportEvent,
) -> FakeTransportChannel {
  let incoming = case channel.incoming {
    None -> {
      let assert Ok(incoming) = process.receive(channel.connections, 50)
      incoming
    }
    Some(i) -> i
  }

  process.send(incoming, event)

  FakeTransportChannel(..channel, incoming: Some(incoming))
}

pub fn receive(channel: FakeTransportChannel) -> List(server_in.Packet) {
  let assert Ok(data) = process.receive(channel.outgoing, 10)
  let assert Ok(#(packets, <<>>)) =
    server_in.decode_packets(bytes_tree.to_bit_array(data))
  packets
}

pub fn flush(channel: FakeTransportChannel) -> FakeTransportChannel {
  case process.receive(channel.outgoing, 0) {
    Error(Nil) -> channel
    Ok(_) -> flush(channel)
  }
}

pub fn close(channel: FakeTransportChannel) -> FakeTransportChannel {
  let assert Some(incoming) = channel.incoming
  process.send(incoming, core.TransportClosed)
  FakeTransportChannel(..channel, incoming: None)
}
