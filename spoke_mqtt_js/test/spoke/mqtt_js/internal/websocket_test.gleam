import drift/js/channel
import gleam/bytes_tree
import gleam/javascript/promise.{type Promise}
import spoke/core
import spoke/mqtt_js/internal/websocket
import websocket_server

pub fn websocket_happy_path_test() -> Promise(Nil) {
  let server = websocket_server.start(1337)
  let inputs = channel.new()

  // Connect
  let socket = websocket.connect("ws://localhost:1337", channel.send(inputs, _))

  // Assert connection is received
  use send_result <- promise.await(channel.receive(server.connections, 10))
  let assert Ok(send) = send_result

  // Assert update is published
  use input_result <- promise.await(channel.receive(inputs, 10))
  assert input_result == Ok(core.Handle(core.TransportEstablished))

  // Assert data sent reaches server
  assert websocket.send(socket, bytes_tree.from_bit_array(<<"Hello!">>))
    == Ok(Nil)
  use receive_result <- promise.await(channel.receive(server.messages, 10))
  assert receive_result == Ok(<<"Hello!">>)

  // Assert data received publishes input
  send(<<"Hi!">>)
  use input_result <- promise.await(channel.receive(inputs, 10))
  assert input_result == Ok(core.Handle(core.ReceivedData(<<"Hi!">>)))

  // Assert connection closes cleanly
  websocket.close(socket)
  use close_result <- promise.await(channel.receive(server.closes, 10))
  assert close_result == Ok(Nil)

  // Assert close gets published
  use input_result <- promise.await(channel.receive(inputs, 10))
  assert input_result == Ok(core.Handle(core.TransportClosed))

  // Clean up
  server.shut_down()
  promise.resolve(Nil)
}

pub fn connect_failure_test() -> Promise(Nil) {
  let inputs = channel.new()
  websocket.connect("ws://localhost:1337", channel.send(inputs, _))

  use input_result <- promise.await(channel.receive(inputs, 10))
  assert input_result
    == Ok(core.Handle(core.TransportFailed("Failed to connect")))

  promise.resolve(Nil)
}

pub fn unexpected_close_test() -> Promise(Nil) {
  let server = websocket_server.start(1337)
  let inputs = channel.new()

  // Connect
  websocket.connect("ws://localhost:1337", channel.send(inputs, _))

  // Consume the connected update
  use _ <- promise.await(channel.receive(inputs, 10))

  // Shut down unexpectedly
  server.shut_down()

  // Assert close gets published
  use input_result <- promise.await(channel.receive(inputs, 10))
  assert input_result == Ok(core.Handle(core.TransportClosed))

  promise.resolve(Nil)
}
