import gleam/erlang/process.{type Subject, type Timer}
import gleam/function
import gleam/otp/actor

// Having either of the following features in gleam would make this much simpler:
// * actor.self - return own Subject
// * process.send_interval - send messages at an interval

// For clearer type definitions
pub type Action =
  fn() -> Nil

pub type Reset =
  fn() -> Nil

/// Does action at interval,
/// unless reset by the returned function.
pub fn start(action: Action, interval interval: Int) -> Reset {
  let assert Ok(pinger) =
    actor.start_spec(actor.Spec(fn() { init(action, interval) }, 100, run))
  fn() { process.send(pinger, Reset) }
}

type State {
  State(action: Action, interval: Int, self: Subject(Message), timer: Timer)
}

type Message {
  Reset
  Send
}

fn init(action: Action, interval: Int) -> actor.InitResult(State, Message) {
  let self = process.new_subject()
  let timer = process.send_after(self, interval, Send)
  let state = State(action, interval, self, timer)

  let selector =
    process.new_selector()
    |> process.selecting(self, function.identity)

  actor.Ready(state, selector)
}

fn run(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Reset -> {
      process.cancel_timer(state.timer)
      Nil
    }
    Send -> {
      state.action()
    }
  }

  let timer = process.send_after(state.self, state.interval, Send)
  actor.continue(State(..state, timer: timer))
}
