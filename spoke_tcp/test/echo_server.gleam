import gleam/bytes_tree
import gleam/erlang/process
import gleam/option.{None}
import glisten.{ConnectionInfo, Packet}

/// Starts an echo server on port 0, and returns the assigned port
pub fn start(on_close: fn() -> Nil) -> Int {
  let listener_name = process.new_name("echo_listener")
  let assert Ok(_) =
    glisten.new(fn(_conn) { #(Nil, None) }, fn(state, msg, conn) {
      let assert Packet(msg) = msg
      case msg {
        <<"stop">> -> glisten.stop()
        _ -> {
          let assert Ok(_) = glisten.send(conn, bytes_tree.from_bit_array(msg))
          glisten.continue(state)
        }
      }
    })
    |> glisten.with_close(fn(_) { on_close() })
    |> glisten.start_with_listener_name(0, listener_name)

  let ConnectionInfo(port, _) = glisten.get_server_info(listener_name, 10)
  port
}
