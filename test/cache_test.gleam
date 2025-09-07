import gleam/erlang/process
import postal_code/cache

pub fn cache_test() {
  let cache_name = process.new_name("cache")
  let assert Ok(_cache) = cache.new(cache_name)

  let cache_subject = process.named_subject(cache_name)
  let test_distance = 244.33
  let test_from = 56_001_962_700
  let test_to = 56_045_951_300
  cache.set_distance(cache_subject, test_distance, test_from, test_to)
  let distance = cache.get_distance(cache_subject, test_from, test_to)
  assert distance == 244.33
}
