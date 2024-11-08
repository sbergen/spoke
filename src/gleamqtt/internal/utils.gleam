import gleam/erlang/process.{type Selector, type Subject}
import gleam/function

pub fn as_selector(subject: Subject(a)) -> Selector(a) {
  process.new_selector() |> process.selecting(subject, function.identity)
}
