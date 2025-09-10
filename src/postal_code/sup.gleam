import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import postal_code/cache
import postal_code/navigator
import postal_code/store

fn start_parser(name: process.Name(store.StoreMessage)) {
  fn() { store.new(name) }
}

fn start_navigator(name: process.Name(navigator.NavigatorMessage)) {
  fn() { navigator.new(name) }
}

fn start_cache(name: process.Name(cache.CacheMessage)) {
  fn() { cache.new(name) }
}

pub fn start_supervisor(
  store_name: process.Name(store.StoreMessage),
  navigator_name: process.Name(navigator.NavigatorMessage),
  cache_name: process.Name(cache.CacheMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervision.worker(start_parser(store_name)))
  |> static_supervisor.add(supervision.worker(start_navigator(navigator_name)))
  |> static_supervisor.add(supervision.worker(start_cache(cache_name)))
  |> static_supervisor.restart_tolerance(intensity: 3, period: 1000)
  |> static_supervisor.supervised()
}
