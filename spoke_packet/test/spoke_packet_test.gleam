import checkmark
import envoy
import gleeunit
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn check_or_update_readme_test() {
  checkmark.new(simplifile.read, simplifile.write)
  |> checkmark.file("README.md")
  |> checkmark.should_contain_contents_of("test/example.gleam", tagged: "gleam")
  |> checkmark.check_or_update(envoy.get("GITHUB_WORKFLOW") == Error(Nil))
}
