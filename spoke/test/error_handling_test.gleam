import fake_server
import spoke

pub fn connection_is_closed_if_actor_crashes_test() {
  let #(client, server) =
    fake_server.set_up_connected_client(clean_session: True)

  spoke.unlink_and_crash(client)

  fake_server.expect_connection_closed(server)
}
