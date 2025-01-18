import gleam/bytes_tree
import gleam/option.{None}
import gleam/otp/actor
import glisten.{ConnectionInfo, Packet}

/// Starts an echo server on port 0, and returns the assigned port
pub fn start(on_close: fn() -> Nil) -> Int {
  let assert Ok(server) =
    glisten.handler(fn(_conn) { #(Nil, None) }, fn(msg, state, conn) {
      let assert Packet(msg) = msg
      let assert Ok(_) = glisten.send(conn, bytes_tree.from_bit_array(msg))
      actor.continue(state)
    })
    |> glisten.with_close(fn(_) { on_close() })
    |> glisten.start_server(0)

  let assert Ok(ConnectionInfo(port, _)) = glisten.get_server_info(server, 10)
  port
}
