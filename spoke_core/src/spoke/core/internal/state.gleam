import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// A monotonically increasing timestamp (we don't care about the unit)
pub type Timestamp =
  Int

/// An ongoing transaction to update the state, timers, or produce outputs.
pub opaque type Transaction(s, t, o, e) {
  Succeed(state: s, timers: List(Timer(t)), outputs: List(o))
  Fail(e)
}

/// An update to be applied to the state
pub type Update(i, t) {
  /// Apply a requested input
  Apply(i)
  /// Apply a timer that expired
  TimerExpired(t)
}

/// An input to process in `update`
pub type Input(i) {
  /// A specific input to apply
  Handle(i)
  /// No input to apply, just trigger all expired timers
  Tick
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
pub fn map(t: Transaction(s, t, o, e), f: fn(s) -> s) -> Transaction(s, t, o, e) {
  case t {
    Succeed(state, ..) -> Succeed(..t, state: f(state))
    Fail(_) as f -> f
  }
}

/// Replaces the state within a transaction
pub fn replace(t: Transaction(s, t, o, e), state: s) -> Transaction(s, t, o, e) {
  case t {
    Succeed(..) -> Succeed(..t, state:)
    Fail(_) as f -> f
  }
}

/// Come up with a better name?
pub fn flat_map(
  t: Transaction(s, t, o, e),
  f: fn(s) -> Transaction(s, t, o, e),
) -> Transaction(s, t, o, e) {
  case t {
    Succeed(state, ..) -> f(state)
    Fail(_) as f -> f
  }
}

/// Starts a timer within a transaction
pub fn start_timer(
  t: Transaction(s, t, o, e),
  timer: Timer(t),
) -> Transaction(s, t, o, e) {
  case t {
    Succeed(timers:, ..) -> Succeed(..t, timers: [timer, ..timers])
    Fail(_) as f -> f
  }
}

/// Cancels a timer within a transaction
pub fn cancel_timer(
  t: Transaction(s, t, o, e),
  predicate: fn(Timer(t)) -> Bool,
) -> Transaction(s, t, o, e) {
  case t {
    Succeed(timers:, ..) ->
      Succeed(..t, timers: list.filter(timers, fn(timer) { !predicate(timer) }))
    Fail(_) as f -> f
  }
}

/// Cancels all timers within a transaction
pub fn cancel_all_timers(t: Transaction(s, t, o, e)) -> Transaction(s, t, o, e) {
  case t {
    Succeed(..) -> Succeed(..t, timers: [])
    Fail(_) as f -> f
  }
}

pub fn output(t: Transaction(s, t, o, e), o: o) -> Transaction(s, t, o, e) {
  case t {
    Succeed(outputs:, ..) -> Succeed(..t, outputs: [o, ..outputs])
    Fail(_) as f -> f
  }
}

pub fn output_many(
  t: Transaction(s, t, o, e),
  os: List(o),
) -> Transaction(s, t, o, e) {
  // TODO: check the list operations below
  case t {
    Succeed(outputs:, ..) ->
      Succeed(..t, outputs: list.append(list.reverse(os), outputs))
    Fail(_) as f -> f
  }
}

/// Adds an output within a transaction
pub fn map_output(
  t: Transaction(s, t, o, e),
  make_output: fn(s) -> o,
) -> Transaction(s, t, o, e) {
  case t {
    Succeed(state:, outputs:, ..) ->
      Succeed(..t, outputs: [make_output(state), ..outputs])
    Fail(_) as f -> f
  }
}

/// Fails the transaction
pub fn fail(_: Transaction(s, t, o, e), error: e) -> Transaction(s, t, o, e) {
  // TODO: support multiple errors?
  Fail(error)
}

/// Triggers all expired timers and applies the given input, if any.
/// On success, returns the new state, next tick deadline, if any,
/// and the list of outputs to apply.
pub fn step(
  state: State(s, t),
  now: Timestamp,
  input: Input(i),
  apply: fn(Transaction(s, t, o, e), Timestamp, Update(i, t)) ->
    Transaction(s, t, o, e),
) -> Result(#(State(s, t), Option(Timestamp), List(o)), e) {
  let State(state, timers) = state

  // Apply timers
  let #(to_trigger, timers) =
    list.partition(timers, fn(timer) { timer.deadline <= now })
  let transaction =
    to_trigger
    |> list.sort(fn(a, b) { int.compare(a.deadline, b.deadline) })
    |> list.fold(Succeed(state, timers, []), fn(transaction, timer) {
      apply(transaction, now, TimerExpired(timer.data))
    })

  // Apply input, if any
  let transaction = case input {
    Handle(input) -> apply(transaction, now, Apply(input))
    Tick -> transaction
  }

  case transaction {
    Fail(e) -> Error(e)
    Succeed(state, timers, outputs) -> {
      Ok(#(State(state, timers), next_tick(timers), list.reverse(outputs)))
    }
  }
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
