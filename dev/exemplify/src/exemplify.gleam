import envoy
import gleam/io
import gleam/option.{Some}
import gleam/regexp
import gleam/string
import simplifile

pub fn update_or_check(source: String) {
  let readme_filename = "./README.md"
  let assert Ok(readme) = simplifile.read(readme_filename)
  let assert Ok(example) = simplifile.read(source)
  let assert Ok(regex) =
    regexp.compile(
      "^```gleam\\n([\\s\\S]*)^```\\n?",
      regexp.Options(case_insensitive: False, multi_line: True),
    )
  let assert [match] = regexp.scan(regex, readme)
  let assert [snippet] = match.submatches

  case snippet == Some(example) {
    True -> Nil
    False -> {
      case envoy.get("GITHUB_WORKFLOW") {
        Error(Nil) -> {
          io.println_error("\nUpdating example in README!")

          // If we only replaced the snippet, this wouldn't work for empty snippets,
          // so we replace the full match instead.
          let with_fences = "```gleam\n" <> example <> "```\n"
          assert simplifile.write(
              to: readme_filename,
              contents: string.replace(readme, match.content, with_fences),
            )
            == Ok(Nil)
          Nil
        }
        Ok(_) -> panic as "Example in README was out of date!"
      }
    }
  }
}
