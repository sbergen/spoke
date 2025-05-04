import fake_server
import spoke
import spoke/packet.{SessionPresent}
import spoke/packet/server/incoming as server_in

pub fn restore_session_success_test() {
  let server = fake_server.start_server()
  let options =
    fake_server.default_connector(server.port)
    |> spoke.connect_with_id("client")

  // First session, no need to even connect
  let client = spoke.start_session(options)
  spoke.publish(
    client,
    spoke.PublishData("topic", <<>>, spoke.AtLeastOnce, False),
  )
  let state = spoke.disconnect(client)

  // Restore session
  let assert Ok(client) = spoke.restore_session(options, state)
    as "Expecting session state to be valid"
  let #(server, _) =
    fake_server.connect_client(client, server, False, SessionPresent)

  let expected_data =
    packet.PublishDataQoS1(packet.MessageData("topic", <<>>, False), True, 1)
  fake_server.expect_packet(server, server_in.Publish(expected_data))
}

pub fn restore_session_failure_test() {
  let options =
    fake_server.default_connector(1883)
    |> spoke.connect_with_id("client")
  let assert Error(_) = spoke.restore_session(options, "{ \"valid\": false }")
}
