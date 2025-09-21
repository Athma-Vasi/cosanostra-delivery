import constants
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/otp/supervision
import warehouse/deliverator
import warehouse/receiver

// --receiver--

type ReceiverPoolName =
  process.Name(receiver.ReceiverPoolMessage)

type ReceiverName =
  process.Name(receiver.ReceiverMessage)

fn generate_receiver_name(max_pool_limit) {
  let names_pool = ["Lagoon", "Ng", "Vitaly Chernobyl"]
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

fn generate_receiver_names(
  names: List(ReceiverName),
  max_pool_limit,
) -> List(ReceiverName) {
  case max_pool_limit == 0 {
    True -> names
    False ->
      generate_receiver_names(
        [generate_receiver_name(max_pool_limit), ..names],
        max_pool_limit - 1,
      )
  }
}

fn start_receiver_pool(
  receiver_pool_name: ReceiverPoolName,
  receiver_names: List(ReceiverName),
) {
  fn() { receiver.new_pool(receiver_pool_name, receiver_names) }
}

fn start_receiver(
  receiver_name: ReceiverName,
  receiver_pool_name: ReceiverPoolName,
  deliverator_pool_name,
  coordinates_store_name,
  coordinates_cache_name,
  navigator_name,
) {
  fn() {
    let receiver_subject = process.named_subject(receiver_name)
    let receiver_pool_subject = process.named_subject(receiver_pool_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)
    let coordinates_store_subject =
      process.named_subject(coordinates_store_name)
    let coordinates_cache_subject =
      process.named_subject(coordinates_cache_name)
    let navigator_subject = process.named_subject(navigator_name)

    receiver.receiver_restart(
      receiver_subject,
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
    )
    receiver.new_receiver(receiver_name)
  }
}

fn start_receivers(
  pool_sup_builder: static_supervisor.Builder,
  receiver_pool_name: ReceiverPoolName,
  receiver_names: List(ReceiverName),
  deliverator_pool_name,
  coordinates_store_name,
  coordinates_cache_name,
  navigator_name,
) -> static_supervisor.Builder {
  receiver_names
  |> list.fold(from: pool_sup_builder, with: fn(acc, receiver_name) {
    acc
    |> static_supervisor.add(
      supervision.worker(start_receiver(
        receiver_name,
        receiver_pool_name,
        deliverator_pool_name,
        coordinates_store_name,
        coordinates_cache_name,
        navigator_name,
      )),
    )
  })
}

// --deliverators--

type DeliveratorPoolName =
  process.Name(deliverator.DeliveratorPoolMessage)

type DeliveratorName =
  process.Name(deliverator.DeliveratorMessage)

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

    deliverator.deliverator_restart(
      deliverator_subject,
      deliverator_pool_subject,
    )
    deliverator.new_deliverator(deliverator_name)
  }
}

fn generate_deliverator_name(max_pool_limit) -> DeliveratorName {
  let names_pool = ["Hiro Protagonist", "Yours Truly"]
  let random_index = names_pool |> list.length |> int.random

  names_pool
  |> list.index_fold(from: "ཐི༏ཋྀ", with: fn(acc, name, index) {
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

fn start_deliverators(
  pool_sup_builder: static_supervisor.Builder,
  deliverator_pool_name: DeliveratorPoolName,
  deliverator_names: List(DeliveratorName),
) -> static_supervisor.Builder {
  deliverator_names
  |> list.fold(from: pool_sup_builder, with: fn(acc, deliverator_name) {
    acc
    |> static_supervisor.add(
      supervision.worker(start_deliverator(
        deliverator_name,
        deliverator_pool_name,
      )),
    )
  })
}

pub fn start_supervisor(
  receiver_pool_name: ReceiverPoolName,
  deliverator_pool_name: DeliveratorPoolName,
  coordinates_store_name,
  coordinates_cache_name,
  navigator_name,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let deliverator_names =
    generate_deliverator_names([], constants.max_pool_limit)
  let receiver_names = generate_receiver_names([], constants.max_pool_limit)

  let pool_sup_builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(start_receiver_pool(receiver_pool_name, receiver_names)),
    )
    |> static_supervisor.add(
      supervision.worker(start_deliverator_pool(
        deliverator_pool_name,
        deliverator_names,
      )),
    )

  start_receivers(
    pool_sup_builder,
    receiver_pool_name,
    receiver_names,
    deliverator_pool_name,
    coordinates_store_name,
    coordinates_cache_name,
    navigator_name,
  )
  |> start_deliverators(deliverator_pool_name, deliverator_names)
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
