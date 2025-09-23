import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import navigator/coordinates_store
import navigator/distances_cache
import navigator/navigator

fn start_parser(name: process.Name(coordinates_store.StoreMessage)) {
  fn() { coordinates_store.new(name) }
}

fn start_navigator(name: process.Name(navigator.NavigatorMessage)) {
  fn() { navigator.new(name) }
}

fn start_distances_cache(name: process.Name(distances_cache.CacheMessage)) {
  fn() { distances_cache.new(name) }
}

pub fn start_navigator_supervisor(
  coordinates_store_name: process.Name(coordinates_store.StoreMessage),
  navigator_name: process.Name(navigator.NavigatorMessage),
  distances_cache_name: process.Name(distances_cache.CacheMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(
    supervision.worker(start_parser(coordinates_store_name)),
  )
  |> static_supervisor.add(supervision.worker(start_navigator(navigator_name)))
  |> static_supervisor.add(
    supervision.worker(start_distances_cache(distances_cache_name)),
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
