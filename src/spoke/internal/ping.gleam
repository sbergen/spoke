import gleam/erlang/process.{type Subject, type Timer}
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
  let assert Ok(pinger) = actor.start(NotStarted(config), run)
  process.send(pinger, Start(pinger))
  fn() { process.send(pinger, Reset) }
}

type Config(a) {
  Config(subject: Subject(a), message: a, interval: Int)
}

type State(a) {
  NotStarted(config: Config(a))
  Waiting(config: Config(a), self: Subject(Message(a)), timer: Timer)
}

type Message(a) {
  Start(Subject(Message(a)))
  Reset
  Send
}

fn run(message: Message(a), state: State(a)) -> actor.Next(Message(a), State(a)) {
  let #(config, self) = case message {
    Start(self) -> {
      let assert NotStarted(config) = state
      #(config, self)
    }
    Reset -> {
      let assert Waiting(config, self, timer) = state
      process.cancel_timer(timer)
      #(config, self)
    }
    Send -> {
      let assert Waiting(config, self, _timer) = state
      process.send(config.subject, config.message)
      #(config, self)
    }
  }

  let timer = process.send_after(self, config.interval, Send)
  actor.continue(Waiting(config, self, timer))
}
