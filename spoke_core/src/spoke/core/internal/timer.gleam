import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Timer(a) {
  Timer(deadline: Int, data: a)
}

pub opaque type TimerPool(a) {
  TimerPool(timers: List(Timer(a)))
}

pub fn new_pool() -> TimerPool(a) {
  TimerPool([])
}

pub fn add(pool: TimerPool(a), timer: Timer(a)) -> TimerPool(a) {
  TimerPool([timer, ..pool.timers])
}

pub fn remove(
  pool: TimerPool(a),
  matching: fn(Timer(a)) -> Bool,
) -> TimerPool(a) {
  TimerPool(list.filter(pool.timers, fn(t) { !matching(t) }))
}

pub fn next(pool: TimerPool(a)) -> Option(Int) {
  case pool.timers {
    [] -> None
    [timer, ..rest] ->
      Some(
        list.fold(rest, timer.deadline, fn(min, timer) {
          int.min(min, timer.deadline)
        }),
      )
  }
}

pub fn drain(
  pool: TimerPool(a),
  until: Int,
  init: s,
  do: fn(s, Timer(a)) -> s,
) -> #(s, TimerPool(a)) {
  let #(result, timers) =
    pool.timers
    |> list.sort(fn(a, b) { int.compare(a.deadline, b.deadline) })
    |> list.fold(#(init, []), fn(acc, timer) {
      let #(state, timers) = acc
      case timer.deadline <= until {
        True -> #(do(state, timer), timers)
        False -> #(state, [timer, ..timers])
      }
    })
  #(result, TimerPool(timers))
}
