import gleam/erlang/process
import postal_code/navigator
import postal_code/store

pub fn navigator_test() {
  let navigator_name = process.new_name("navigator")
  let navigator_subject = process.named_subject(navigator_name)
  let assert Ok(_navigator) = navigator.new(navigator_name)
  let store_name = process.new_name("parser_store")
  let assert Ok(_store) = store.new(store_name)
  let store_subject = process.named_subject(store_name)
  let distance =
    navigator.get_distance(
      navigator_subject,
      56_001_962_700,
      56_001_962_800,
      store_subject,
    )

  assert distance == 2.17
}
