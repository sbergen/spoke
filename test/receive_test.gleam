import gleam/erlang/process
import gleam/option.{None}
import spoke
import spoke/internal/packet
import spoke/internal/packet/client/incoming
import test_client

pub fn receive_message_test() {
  let #(client, _, receives, _, updates) =
    test_client.set_up_connected(keep_alive: 1000, server_timeout: 100)

  let data =
    packet.PublishData(
      topic: "topic0",
      payload: <<"payload">>,
      dup: True,
      qos: packet.QoS0,
      retain: False,
      packet_id: None,
    )

  test_client.simulate_server_response(receives, incoming.Publish(data))

  let assert Ok(spoke.ReceivedMessage(_, _, _)) = process.receive(updates, 10)

  spoke.disconnect(client)
}
