import birdie
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import spoke/core/internal/state

type Event {
  PrintTime
}

type Operation {
  Append(String)
  Yank
  PrintMe
  Stop
}

type Output {
  Print(String)
}

type Step =
  state.Step(List(String), Event, Output)

pub fn state_happy_path_test() -> Nil {
  let state = state.new(["Hello, World!"], [state.Timer(10, PrintTime)])

  let assert #(state, Some(10), []) =
    state.step(state, 0, Append("Wibble!"), apply)

  let assert #(state, Some(20), []) = state.tick(state, 10, handle_timeout)

  let assert #(state, Some(20), []) =
    state.step(state, 15, Append("Wobble"), apply)

  let assert #(state, Some(20), []) =
    state.step(state, 16, Append("Wobble"), apply)

  let assert #(state, Some(20), []) = state.step(state, 17, Yank, apply)

  let assert #(state, Some(30), []) = state.tick(state, 20, handle_timeout)

  let assert #(_, _, [Print(log)]) = state.step(state, 25, PrintMe, apply)

  let assert #(_, None, _) = state.step(state, 25, Stop, apply)

  birdie.snap(log, "State updates work when no errors")
}

fn apply(transaction: Step, now: state.Timestamp, operation: Operation) -> Step {
  case operation {
    Yank -> state.map(transaction, list.drop(_, 1))

    Append(message) -> {
      use lines <- state.map(transaction)
      [string.inspect(now) <> ": " <> message, ..lines]
    }

    PrintMe -> {
      use lines <- state.flat_map(transaction)
      state.output(
        transaction,
        Print(
          lines
          |> list.reverse
          |> string.join("\n"),
        ),
      )
    }

    Stop -> state.cancel_all_timers(transaction)
  }
}

fn handle_timeout(transaction: Step, now: state.Timestamp, event: Event) {
  case event {
    PrintTime -> {
      let new_line = "It's now: " <> string.inspect(now)
      transaction
      |> state.map(list.prepend(_, new_line))
      |> state.start_timer(state.Timer(now + 10, PrintTime))
    }
  }
}
