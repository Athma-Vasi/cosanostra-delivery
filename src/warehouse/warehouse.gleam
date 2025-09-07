import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor
import gleam/string
import postal_code/navigator
import postal_code/sup
import youid/uuid

pub fn start() -> Nil {
  let store_name = process.new_name("parser_store")
  let navigator_name = process.new_name("navigator")
  let cache_name = process.new_name("cache")

  let sup_spec = sup.start_supervisor(store_name, navigator_name, cache_name)
  let assert Ok(_overmind) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(sup_spec)
    |> static_supervisor.start()

  let store_subject = process.named_subject(store_name)
  let navigator_subject = process.named_subject(navigator_name)
  let cache_subject = process.named_subject(cache_name)

  let distance =
    navigator.get_distance(
      navigator_subject,
      56_001_962_700,
      56_045_951_300,
      store_subject,
      cache_subject,
    )

  distance |> float.to_string |> io.println
}

pub fn random() -> String {
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
      let rand_content = random()
      let updated = batch |> dict.insert(rand_id, rand_content)
      random_batch_helper(updated, amount - 1)
    }
  }
}

pub fn random_batch(amount: Int) {
  random_batch_helper(dict.new(), amount)
}
