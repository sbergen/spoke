import checkmark
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn validate_readme_test() {
  let assert Ok([Ok(_)]) =
    checkmark.new()
    |> checkmark.using(checkmark.Build)
    |> checkmark.check_in_current_package("checkmark_tmp.gleam")
}
