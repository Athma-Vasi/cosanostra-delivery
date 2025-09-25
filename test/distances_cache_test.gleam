import gleam/erlang/process
import gleam/result
import navigator/distances_cache

pub fn distances_cache_test() {
  let distances_cache_name = process.new_name("distances_cache")
  let assert Ok(_distances_cache) = distances_cache.new(distances_cache_name)

  let distances_cache_subject = process.named_subject(distances_cache_name)
  let test_distance = 244.33
  let test_from = 56_001_962_700
  let test_to = 56_045_951_300
  distances_cache.set_distance(
    distances_cache_subject,
    test_distance,
    test_from,
    test_to,
  )
  let distance =
    distances_cache.get_distance(distances_cache_subject, test_from, test_to)
    |> result.unwrap(0.0)
  assert distance != 0.0 && distance == 244.33
}
