import gleam/option.{None, Some}
import spoke/core/internal/timer.{Timer}

pub fn single_timer_test() {
  let timers = timer.new_pool()
  let assert None = timer.next(timers) as "no timers added yet"

  let timers = timer.add(timers, Timer(10, 42))
  let assert Some(10) = timer.next(timers) as "next deadline should match"
  let assert #([], timers) = timer.drain(timers, 9)
  let assert #([Timer(10, 42)], timers) = timer.drain(timers, 10)
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
  let assert #([Timer(10, 10), Timer(20, 20)], timers) = timer.drain(timers, 29)
  let timers = timers |> timer.remove(fn(t) { t.data == 50 })
  let assert #([Timer(30, 30)], timers) = timer.drain(timers, 100)
  let assert None = timer.next(timers)
}
