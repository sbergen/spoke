import checkmark
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn validate_readme_test() {
  checkmark.new()
  |> checkmark.using(checkmark.Build)
  |> checkmark.check_in_current_package("checkmark_tmp.gleam")
  |> checkmark.print_failures(panic_if_failed: True)
}
