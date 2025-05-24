import gleam/option.{Some}
import gleeunit
import spoke/mqtt

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn connect_options_test() {
  let assert mqtt.ConnectOptions(
    "fake-transport-options",
    "client-id",
    Some(mqtt.AuthDetails("user", Some(<<"Hunter2">>))),
    42,
    420,
  ) =
    "fake-transport-options"
    |> mqtt.connect_with_id("client-id")
    |> mqtt.using_auth("user", Some(<<"Hunter2">>))
    |> mqtt.keep_alive_seconds(42)
    |> mqtt.server_timeout_ms(420)
    as "Connect option modifiers should be properly applied"
}
