import gleam/erlang/process
import navigator/coordinates_store
import navigator/distances_cache
import navigator/navigator

pub fn navigator_test() {
  let navigator_name = process.new_name("navigator")
  let navigator_subject = process.named_subject(navigator_name)
  let assert Ok(_navigator) = navigator.new(navigator_name)
  let coordinates_store_name = process.new_name("parser_coordinates_store")
  let assert Ok(_coordinates_store) =
    coordinates_store.new(coordinates_store_name)
  let coordinates_store_subject = process.named_subject(coordinates_store_name)
  let distances_cache_name = process.new_name("distances_cache")
  let distances_cache_subject = process.named_subject(distances_cache_name)
  let assert Ok(_distances_cache) = distances_cache.new(distances_cache_name)

  let distance =
    navigator.get_distance(
      navigator_subject,
      56_001_962_700,
      56_001_962_800,
      coordinates_store_subject,
      distances_cache_subject,
    )

  assert distance == 2.15
}
