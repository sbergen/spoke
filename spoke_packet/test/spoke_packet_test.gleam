import exemplify
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn check_or_update_readme_test() {
  exemplify.update_or_check("./dev/example.gleam")
}
