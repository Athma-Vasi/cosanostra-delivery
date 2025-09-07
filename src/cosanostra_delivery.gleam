import gleam/erlang/process
import gleam/float
import gleam/io
import gleam/otp/static_supervisor as supervisor
import postal_code/navigator
import postal_code/sup

pub fn main() -> Nil {
  let store_name = process.new_name("parser_store")
  let navigator_name = process.new_name("navigator")
  let cache_name = process.new_name("cache")

  let store_subject = process.named_subject(store_name)
  let navigator_subject = process.named_subject(navigator_name)
  let cache_subject = process.named_subject(cache_name)

  let sup_spec = sup.start_supervisor(store_name, navigator_name, cache_name)
  let assert Ok(_overmind) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(sup_spec)
    |> supervisor.start()

  let distance =
    navigator.get_distance(
      navigator_subject,
      56_001_962_700,
      56_045_951_300,
      store_subject,
      cache_subject,
    )
  io.println(float.to_string(distance))
  Nil
}
