import constants
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/otp/supervision
import navigator/coordinates_store
import navigator/distances_cache
import navigator/navigator
import warehouse/deliverator
import warehouse/receiver

// --deliverator--

type DeliveratorPoolName =
  process.Name(deliverator.DeliveratorPoolMessage)

type DeliveratorName =
  process.Name(deliverator.DeliveratorMessage)

fn generate_deliverator_name(max_pool_limit) {
  let names_pool = ["Hiro Protagonist", "Yours Truly", "Vitaly Chernobyl"]
  let random_index = names_pool |> list.length |> int.random

  names_pool
  |> list.index_fold(from: "Juanita", with: fn(acc, name, index) {
    case index == random_index {
      True -> name <> int.to_string(max_pool_limit)
      False -> acc
    }
  })
  |> process.new_name
}

fn generate_deliverator_names(
  names: List(DeliveratorName),
  max_pool_limit,
) -> List(DeliveratorName) {
  case max_pool_limit == 0 {
    True -> names
    False ->
      generate_deliverator_names(
        [generate_deliverator_name(max_pool_limit), ..names],
        max_pool_limit - 1,
      )
  }
}

fn start_deliverator_pool(
  deliverator_pool_name: DeliveratorPoolName,
  deliverator_names: List(DeliveratorName),
) {
  fn() { deliverator.new_pool(deliverator_pool_name, deliverator_names) }
}

fn start_deliverator(
  deliverator_name: DeliveratorName,
  deliverator_pool_name: DeliveratorPoolName,
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    // restart counts are tracked in the deliverator pool
    deliverator.deliverator_restart(
      deliverator_subject,
      deliverator_pool_subject,
    )
    deliverator.new_deliverator(deliverator_name)
  }
}

fn start_deliverators(
  deliverator_sup_builder: static_supervisor.Builder,
  deliverator_pool_name: DeliveratorPoolName,
  deliverator_names: List(DeliveratorName),
) -> static_supervisor.Builder {
  deliverator_names
  |> list.fold(from: deliverator_sup_builder, with: fn(sup, name) {
    sup
    |> static_supervisor.add(
      supervision.worker(start_deliverator(name, deliverator_pool_name)),
    )
  })
}

fn start_deliverator_pool_supervisor(
  deliverator_pool_name: DeliveratorPoolName,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let deliverator_names =
    generate_deliverator_names([], constants.deliverator_pool_limit)

  let deliverator_sup_builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(start_deliverator_pool(
        deliverator_pool_name,
        deliverator_names,
      )),
    )

  start_deliverators(
    deliverator_sup_builder,
    deliverator_pool_name,
    deliverator_names,
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}

// --receiver--

type ReceiverPoolName =
  process.Name(receiver.ReceiverPoolMessage)

fn start_receiver_pool(
  receiver_pool_name: ReceiverPoolName,
  coordinates_store_name: process.Name(coordinates_store.StoreMessage),
  distances_cache_name: process.Name(distances_cache.CacheMessage),
  navigator_name: process.Name(navigator.NavigatorMessage),
  deliverator_pool_name: DeliveratorPoolName,
) {
  fn() {
    receiver.new_pool(
      receiver_pool_name,
      coordinates_store_name,
      distances_cache_name,
      navigator_name,
      deliverator_pool_name,
    )
  }
}

fn start_receiver_pool_supervisor(
  receiver_pool_name: ReceiverPoolName,
  deliverator_pool_name: DeliveratorPoolName,
  coordinates_store_name: process.Name(coordinates_store.StoreMessage),
  distances_cache_name: process.Name(distances_cache.CacheMessage),
  navigator_name: process.Name(navigator.NavigatorMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(
    supervision.worker(start_receiver_pool(
      receiver_pool_name,
      coordinates_store_name,
      distances_cache_name,
      navigator_name,
      deliverator_pool_name,
    )),
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}

pub fn start_warehouse_supervisor(
  receiver_pool_name,
  deliverator_pool_name,
  coordinates_store_name,
  distances_cache_name,
  navigator_name,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let deliverator_sup_spec =
    start_deliverator_pool_supervisor(deliverator_pool_name)

  let receiver_sup_spec =
    start_receiver_pool_supervisor(
      receiver_pool_name,
      deliverator_pool_name,
      coordinates_store_name,
      distances_cache_name,
      navigator_name,
    )

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(deliverator_sup_spec)
  |> static_supervisor.add(receiver_sup_spec)
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
