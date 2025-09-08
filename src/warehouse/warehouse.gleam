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
