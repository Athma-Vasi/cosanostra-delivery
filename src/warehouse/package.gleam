import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import youid/uuid

pub fn random_content() -> String {
  let content_options = ["Book", "Broom", "Soap", "Pen"]
  let rand_idx = content_options |> list.length |> int.random
  let content =
    content_options
    |> list.index_fold(from: "", with: fn(acc, curr, idx) {
      case idx == rand_idx {
        True -> curr
        False -> acc
      }
    })
  content
}

pub fn generate_package_id() -> String {
  uuid.v4_string()
  |> string.replace(each: "-", with: "X")
  |> string.replace(each: "_", with: "X")
}

fn random_batch_helper(batch: dict.Dict(String, String), amount) {
  case amount == 0 {
    True -> batch
    False -> {
      let rand_id = generate_package_id()
      let rand_content = random_content()
      let updated = batch |> dict.insert(rand_id, rand_content)
      random_batch_helper(updated, amount - 1)
    }
  }
}

pub fn random_batch(amount: Int) {
  random_batch_helper(dict.new(), amount)
}
