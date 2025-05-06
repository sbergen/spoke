import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// A monotonically increasing timestamp (we don't care about the unit)
pub type Timestamp =
  Int

/// An ongoing transaction to update the state, timers, or produce outputs.
pub opaque type Step(s, t, o) {
  Step(state: s, timers: List(Timer(t)), outputs: List(o))
}

/// A timer that wil expire when the timestamp increases to this point.
/// The creator of the timer needs to ensure that the data is unique enough
/// to be identified, if the timer is to be canceled.
pub type Timer(t) {
  Timer(deadline: Timestamp, data: t)
}

/// Holds the current state data and active timers.
pub opaque type State(s, t) {
  State(state: s, timers: List(Timer(t)))
}

/// Create a new state holder with the initial state and timers.
pub fn new(state: s, timers: List(Timer(t))) -> State(s, t) {
  State(state, timers)
}

/// Updates the state within a transaction
pub fn map(t: Step(s, t, o), f: fn(s) -> s) -> Step(s, t, o) {
  Step(..t, state: f(t.state))
}

/// Replaces the state within a transaction
pub fn replace(t: Step(s, t, o), state: s) -> Step(s, t, o) {
  Step(..t, state:)
}

/// Come up with a better name?
pub fn flat_map(t: Step(s, t, o), f: fn(s) -> x) -> x {
  f(t.state)
}

/// Starts a timer within a transaction
pub fn start_timer(t: Step(s, t, o), timer: Timer(t)) -> Step(s, t, o) {
  Step(..t, timers: [timer, ..t.timers])
}

/// Cancels a timer within a transaction
pub fn cancel_timer(
  t: Step(s, t, o),
  predicate: fn(Timer(t)) -> Bool,
) -> Step(s, t, o) {
  Step(..t, timers: list.filter(t.timers, fn(timer) { !predicate(timer) }))
}

/// Cancels all timers within a transaction
pub fn cancel_all_timers(t: Step(s, t, o)) -> Step(s, t, o) {
  Step(..t, timers: [])
}

pub fn output(t: Step(s, t, o), o: o) -> Step(s, t, o) {
  Step(..t, outputs: [o, ..t.outputs])
}

pub fn output_many(t: Step(s, t, o), os: List(o)) -> Step(s, t, o) {
  // TODO: check the list operations below
  Step(..t, outputs: list.append(list.reverse(os), t.outputs))
}

/// Adds an output within a transaction
pub fn map_output(t: Step(s, t, o), make_output: fn(s) -> o) -> Step(s, t, o) {
  Step(..t, outputs: [make_output(t.state), ..t.outputs])
}

pub fn error(t: Step(s, t, o), e: fn(s) -> e) -> Result(Step(s, t, o), e) {
  Error(e(t.state))
}

/// Triggers all expired timers.
/// Returns the new state, next tick deadline, if any,
/// and the list of outputs to apply.
pub fn tick(
  state: State(s, t),
  now: Timestamp,
  apply: fn(Step(s, t, o), Timestamp, t) -> Step(s, t, o),
) -> #(State(s, t), Option(Timestamp), List(o)) {
  let State(state, timers) = state
  let #(to_trigger, timers) =
    list.partition(timers, fn(timer) { timer.deadline <= now })

  let Step(state, timers, outputs) =
    to_trigger
    |> list.sort(fn(a, b) { int.compare(a.deadline, b.deadline) })
    |> list.fold(Step(state, timers, []), fn(transaction, timer) {
      apply(transaction, now, timer.data)
    })

  #(State(state, timers), next_tick(timers), list.reverse(outputs))
}

pub fn begin_step(state: State(s, t)) -> Step(s, t, _) {
  Step(state.state, state.timers, [])
}

pub fn end_step(
  step: Step(s, t, o),
) -> #(State(s, t), Option(Timestamp), List(o)) {
  let Step(state, timers, outputs) = step
  #(State(state, timers), next_tick(timers), list.reverse(outputs))
}

pub fn step(
  state: State(s, t),
  now: Timestamp,
  input: i,
  apply: fn(Step(s, t, o), Timestamp, i) -> Step(s, t, o),
) -> #(State(s, t), Option(Timestamp), List(o)) {
  state
  |> begin_step()
  |> apply(now, input)
  |> end_step
}

pub fn wrap(
  result: #(State(s, t), Option(Timestamp), List(o)),
  wrap: fn(State(s, t)) -> a,
) -> #(a, Option(Timestamp), List(o)) {
  #(wrap(result.0), result.1, result.2)
}

fn next_tick(timers: List(Timer(_))) -> Option(Timestamp) {
  case timers {
    [] -> None
    [timer, ..rest] ->
      Some(
        list.fold(rest, timer.deadline, fn(min, timer) {
          int.min(min, timer.deadline)
        }),
      )
  }
}
