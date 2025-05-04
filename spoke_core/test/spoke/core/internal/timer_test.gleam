import gleam/option.{None, Some}
import spoke/core/internal/timer

pub fn single_timer_test() {
  let timers = timer.new_pool()
  let assert None = timer.next(timers) as "no timers added yet"

  let timers = timer.add(timers, timer.Timer(10, 42))
  let assert Some(10) = timer.next(timers) as "next deadline should match"

  let #(sum, timers) = timer.drain(timers, 9, 0, timer_sum)
  let assert 0 = sum as "timer should not fire yet"

  let #(sum, timers) = timer.drain(timers, 10, 0, timer_sum)
  let assert 42 = sum as "timer should fire"

  let assert None = timer.next(timers) as "drain should remove timer"
}

pub fn multiple_timer_test() {
  let timers =
    timer.new_pool()
    |> timer.add(timer.Timer(20, 20))
    |> timer.add(timer.Timer(50, 50))
    |> timer.add(timer.Timer(30, 30))
    |> timer.add(timer.Timer(10, 10))

  let assert Some(10) = timer.next(timers)
  let assert #(30, timers) = timer.drain(timers, 29, 0, timer_sum)
  let timers = timers |> timer.remove(fn(t) { t.data == 50 })
  let assert #(30, timers) = timer.drain(timers, 100, 0, timer_sum)
  let assert None = timer.next(timers)
}

fn timer_sum(sum: Int, timer: timer.Timer(Int)) -> Int {
  sum + timer.data
}
