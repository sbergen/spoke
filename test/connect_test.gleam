import gleam/erlang/process
import gleam/otp/task
import gleeunit/should
import spoke
import spoke/internal/packet/incoming
import spoke/internal/packet/outgoing
import spoke/internal/transport
import test_client

pub fn connect_success_test() {
  let keep_alive_s = 15
  let #(client, sent_packets, receives, _, _) =
    test_client.set_up_disconnected(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 1000) })

  // Connect request
  let assert Ok(request) = process.receive(sent_packets, 10)
  request
  |> should.equal(outgoing.Connect(test_client.client_id, keep_alive_s))

  // Connect response
  test_client.simulate_server_response(receives, incoming.ConnAck(Ok(False)))

  let assert Ok(Ok(False)) = task.try_await(connect_task, 10)

  spoke.disconnect(client)
}

pub fn disconnects_after_server_rejects_connect_test() {
  let keep_alive_s = 15
  let #(client, _, receives, disconnects, updates) =
    test_client.set_up_disconnected(keep_alive_s * 1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 10) })

  // Connect response
  test_client.simulate_server_response(
    receives,
    incoming.ConnAck(Error(incoming.BadUsernameOrPassword)),
  )

  let assert Ok(Error(spoke.BadUsernameOrPassword)) =
    task.try_await(connect_task, 10)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn aborted_connect_disconnects_with_correct_status_test() {
  let #(client, _, receives, disconnects, updates) =
    test_client.set_up_disconnected(1000, server_timeout: 100)

  let connect_task = task.async(fn() { spoke.connect(client, 10) })
  // Open channel
  let assert Ok(_) = process.receive(receives, 10)

  spoke.disconnect(client)

  let assert Ok(Error(spoke.DisconnectRequested)) =
    task.try_await(connect_task, 10)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn timed_out_connect_disconnects_test() {
  let #(client, _, _, disconnects, updates) =
    test_client.set_up_disconnected(1000, server_timeout: 100)

  // The timeout used for connect is what matters (server timeout does not)
  let assert Error(spoke.ConnectTimedOut) = spoke.connect(client, 2)
  let assert Ok(Nil) = process.receive(disconnects, 1)
  let assert Ok(spoke.Disconnected) = process.receive(updates, 1)
}

pub fn connecting_when_already_connected_fails_test() {
  let #(client, _, receives, _, _) =
    test_client.set_up_disconnected(1000, server_timeout: 100)

  let task_started = process.new_subject()
  let initial_connect =
    task.async(fn() {
      process.send(task_started, Nil)
      spoke.connect(client, 4)
    })

  let assert Ok(Nil) = process.receive(task_started, 2)
  let assert Error(spoke.AlreadyConnected) = spoke.connect(client, 4)

  // initial connect should still succeed
  test_client.simulate_server_response(receives, incoming.ConnAck(Ok(False)))
  let assert Ok(Ok(False)) = task.try_await(initial_connect, 10)
}

pub fn channel_connect_error_fails_connect_test() {
  let connect = fn() { Error(transport.ChannelClosed) }
  let updates = process.new_subject()
  let client = spoke.run("client-id", 1000, 100, connect, updates)

  let assert Error(spoke.ConnectChannelError("ChannelClosed")) =
    spoke.connect(client, 2)
}

pub fn channel_error_on_connect_packet_fails_connect_call_test() {
  let shutdowns = process.new_subject()
  let connect = fn() {
    Ok(
      transport.Channel(
        send: fn(_) { Error(transport.ChannelClosed) },
        selecting_next: fn(_) { process.new_selector() },
        shutdown: fn() { process.send(shutdowns, Nil) },
      ),
    )
  }
  let updates = process.new_subject()
  let client = spoke.run("client-id", 1000, 100, connect, updates)

  let assert Error(spoke.ConnectChannelError("ChannelClosed")) =
    spoke.connect(client, 2)
}
