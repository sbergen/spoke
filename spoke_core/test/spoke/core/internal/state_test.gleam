import birdie
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import spoke/core/internal/state.{Handle, Tick}

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

type Transaction =
  state.Transaction(List(String), Event, Output, String)

type Update =
  state.Update(Operation, Event)

pub fn state_happy_path_test() -> Nil {
  let state = state.new(["Hello, World!"], [state.Timer(10, PrintTime)])

  let assert Ok(#(state, Some(10), [])) =
    state.step(state, 0, Handle(Append("Wibble!")), apply)

  let assert Ok(#(state, Some(20), [])) = state.step(state, 10, Tick, apply)

  let assert Ok(#(state, Some(20), [])) =
    state.step(state, 15, Handle(Append("Wobble")), apply)

  let assert Ok(#(state, Some(20), [])) =
    state.step(state, 16, Handle(Append("Wobble")), apply)

  let assert Ok(#(state, Some(20), [])) =
    state.step(state, 17, Handle(Yank), apply)

  let assert Ok(#(state, Some(30), [])) = state.step(state, 20, Tick, apply)

  let assert Ok(#(_, _, [Print(log)])) =
    state.step(state, 25, Handle(PrintMe), apply)

  let assert Ok(#(_, None, _)) = state.step(state, 25, Handle(Stop), apply)

  birdie.snap(log, "State updates work when no errors")
}

fn apply(
  transaction: Transaction,
  now: state.Timestamp,
  update: Update,
) -> Transaction {
  case update {
    state.TimerExpired(event) ->
      case event {
        PrintTime -> {
          let new_line = "It's now: " <> string.inspect(now)
          transaction
          |> state.map(list.prepend(_, new_line))
          |> state.start_timer(state.Timer(now + 10, PrintTime))
        }
      }

    state.Apply(operation) ->
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
}
