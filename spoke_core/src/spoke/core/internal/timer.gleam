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

pub fn drain(pool: TimerPool(a), until: Int) -> #(List(Timer(a)), TimerPool(a)) {
  let #(before, after) =
    list.partition(pool.timers, fn(timer) { timer.deadline <= until })

  let before =
    list.sort(before, fn(a, b) { int.compare(a.deadline, b.deadline) })

  #(before, TimerPool(after))
}
