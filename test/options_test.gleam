import gleam/option.{Some}
import spoke
import spoke/tcp

pub fn connect_options_test() {
  let assert spoke.ConnectOptions(
    _,
    "client-id",
    Some(spoke.AuthDetails("user", Some(<<"Hunter2">>))),
    42,
    420,
  ) =
    tcp.connector_with_defaults("")
    |> spoke.connect_with_id("client-id")
    |> spoke.using_auth("user", Some(<<"Hunter2">>))
    |> spoke.keep_alive_seconds(42)
    |> spoke.server_timeout_ms(420)
    as "Connect option modifiers should be properly applied"
}
