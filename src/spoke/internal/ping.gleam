import gleam/erlang/process.{type Subject, type Timer}
import gleam/function
import gleam/otp/actor

// Having either of the following features in gleam would make this much simpler:
// * actor.self - return own Subject
// * process.send_interval - send messages at an interval

/// Sends message to subject at interval,
/// unless reset by the returned function.
pub fn start(
  subject: Subject(a),
  message: a,
  interval interval: Int,
) -> fn() -> Nil {
  let config = Config(subject, message, interval)
  let assert Ok(pinger) =
    actor.start_spec(actor.Spec(fn() { init(config) }, 100, run))
  fn() { process.send(pinger, Reset) }
}

type Config(a) {
  Config(subject: Subject(a), message: a, interval: Int)
}

type State(a) {
  State(config: Config(a), self: Subject(Message), timer: Timer)
}

type Message {
  Reset
  Send
}

fn init(config: Config(a)) -> actor.InitResult(State(a), Message) {
  let self = process.new_subject()
  let timer = process.send_after(self, config.interval, Send)
  let state = State(config, self, timer)

  let selector =
    process.new_selector()
    |> process.selecting(self, function.identity)

  actor.Ready(state, selector)
}

fn run(message: Message, state: State(a)) -> actor.Next(Message, State(a)) {
  case message {
    Reset -> {
      process.cancel_timer(state.timer)
      Nil
    }
    Send -> {
      send(state.config)
    }
  }

  let timer = process.send_after(state.self, state.config.interval, Send)
  actor.continue(State(..state, timer: timer))
}

fn send(config: Config(a)) -> Nil {
  process.send(config.subject, config.message)
}
