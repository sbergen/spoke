import spoke

pub fn tcp_options_test() {
  let assert spoke.TcpOptions("host", 42, 420) =
    spoke.default_tcp_options("host")
    |> spoke.tcp_port(42)
    |> spoke.tcp_connect_timeout(420)
    as "TCP option modifiers should be properly applied"
}

pub fn connect_options_test() {
  let assert spoke.ConnectOptions(_, "client-id", 42, 420) =
    spoke.default_tcp_options("")
    |> spoke.connect_with_id("client-id")
    |> spoke.keep_alive_seconds(42)
    |> spoke.server_timeout_ms(420)
    as "Connect option modifiers should be properly applied"
}
