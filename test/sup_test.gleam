import gleam/erlang/process
import postal_code/navigator
import postal_code/sup

pub fn sup_test() {
  let store_name = process.new_name("parser_store")
  let navigator_name = process.new_name("navigator")
  let cache_name = process.new_name("cache")
  let #(store_subject, navigator_subject, cache_subject) =
    sup.start_supervisor(store_name, navigator_name, cache_name)
  let distance =
    navigator.get_distance(
      navigator_subject,
      56_001_962_700,
      56_045_951_300,
      store_subject,
      cache_subject,
    )

  assert distance == 244.33
}
