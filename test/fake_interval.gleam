import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import spoke/internal/interval

pub opaque type FakeInterval {
  FakeInterval(subject: Subject(Message))
}

pub fn new() -> FakeInterval {
  let assert Ok(subject) = actor.start(NotStarted, run)
  FakeInterval(subject)
}

pub fn start(
  fake: FakeInterval,
  action: interval.Action,
  interval: Int,
) -> interval.Reset {
  process.send(fake.subject, Start(action, interval))
  fn() { process.send(fake.subject, Reset) }
}

pub fn get_interval(fake: FakeInterval) -> Option(Int) {
  process.call(fake.subject, GetInterval, 10)
}

pub fn get_and_clear_reset(fake: FakeInterval) -> Bool {
  process.call(fake.subject, GetAndClearReset, 10)
}

pub fn timeout(fake: FakeInterval) -> Nil {
  process.send(fake.subject, Timeout)
}

type State {
  NotStarted
  Started(reset: Bool, action: interval.Action, interval: Int)
}

type Message {
  GetInterval(Subject(Option(Int)))
  GetAndClearReset(Subject(Bool))
  Start(action: interval.Action, interval: Int)
  Reset
  Timeout
}

fn run(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    GetInterval(reply_to) -> {
      case state {
        NotStarted -> process.send(reply_to, None)
        Started(_, _, interval) -> process.send(reply_to, Some(interval))
      }
      actor.continue(state)
    }
    GetAndClearReset(reply_to) -> {
      let assert Started(reset, action, interval) = state
      process.send(reply_to, reset)
      actor.continue(Started(False, action, interval))
    }
    Reset -> {
      let assert Started(_, action, interval) = state
      actor.continue(Started(True, action, interval))
    }
    Start(action, interval) -> {
      let assert NotStarted = state
      actor.continue(Started(False, action, interval))
    }
    Timeout -> {
      let assert Started(_, action, _) = state
      action()
      actor.continue(state)
    }
  }
}
