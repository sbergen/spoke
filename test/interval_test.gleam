import gleam/erlang/process
import spoke/internal/interval

// Testing timeouts without simulating time is not exactly reliable.
// Tweaking this value until they are good enough ¯\_(ツ)_/¯ 
const interval = 4

pub fn timing_out_sends_messages_when_not_canceled_test() {
  let subject = process.new_subject()
  let _ = interval.start(fn() { process.send(subject, "wibble") }, interval)

  // Wait for 2x the interval, just to be relatively sure we don't spuriously fail
  let assert Ok("wibble") = process.receive(subject, 2 * interval)
  let assert Ok("wibble") = process.receive(subject, 2 * interval)
  let assert Error(_) = process.receive(subject, 0)
}

pub fn resetting_delays_send_test() {
  let subject = process.new_subject()
  let reset = interval.start(fn() { process.send(subject, "wibble") }, interval)

  process.sleep(interval / 2)
  reset()
  process.sleep(interval / 2)
  reset()
  process.sleep(interval / 2)

  let assert Error(_) = process.receive(subject, 0)
  let assert Ok("wibble") = process.receive(subject, interval)
}
