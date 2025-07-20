import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import spoke/core.{type TransportEvent}
import spoke/mqtt_actor.{type TransportChannelConnector, TransportChannel}
import spoke/packet
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub opaque type FakeServer {
  FakeServer(
    connections: Subject(Subject(TransportEvent)),
    incoming: Option(Subject(TransportEvent)),
    outgoing: Subject(BytesTree),
  )
}

pub fn new() -> #(TransportChannelConnector, FakeServer) {
  let outgoing_data = process.new_subject()
  let connections = process.new_subject()

  let connector = fn() {
    let incoming_data = process.new_subject()
    let selector = process.new_selector() |> process.select(incoming_data)
    process.send(connections, incoming_data)

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

  let server = FakeServer(connections, None, outgoing_data)
  #(connector, server)
}

pub fn establish_connection(
  server: FakeServer,
  result: packet.ConnAckResult,
) -> FakeServer {
  server
  |> send_event(core.TransportEstablished)
  |> send(server_out.ConnAck(result))
}

pub fn send(server: FakeServer, packet: server_out.Packet) -> FakeServer {
  let data = bytes_tree.to_bit_array(server_out.encode_packet(packet))
  send_event(server, core.ReceivedData(data))
}

fn send_event(server: FakeServer, event: TransportEvent) -> FakeServer {
  let incoming = case server.incoming {
    None -> {
      let assert Ok(incoming) = process.receive(server.connections, 50)
      incoming
    }
    Some(i) -> i
  }

  process.send(incoming, event)

  FakeServer(..server, incoming: Some(incoming))
}

pub fn receive(server: FakeServer) -> List(server_in.Packet) {
  let assert Ok(data) = process.receive(server.outgoing, 10)
  let assert Ok(#(packets, <<>>)) =
    server_in.decode_packets(bytes_tree.to_bit_array(data))
  packets
}

pub fn flush(server: FakeServer) -> FakeServer {
  case process.receive(server.outgoing, 0) {
    Error(Nil) -> server
    Ok(_) -> flush(server)
  }
}

pub fn close(server: FakeServer) -> FakeServer {
  let assert Some(incoming) = server.incoming
  process.send(incoming, core.TransportClosed)
  FakeServer(..server, incoming: None)
}
