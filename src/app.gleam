import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import navigator/sup as navigator_sup
import warehouse/package
import warehouse/receiver
import warehouse/sup as warehouse_sup

pub fn start() {
  let coordinates_store_name = process.new_name(constants.coordinates_store)
  let navigator_name = process.new_name(constants.navigator)
  let distances_cache_name = process.new_name(constants.distances_cache)
  let deliverator_pool_name = process.new_name(constants.deliverator_pool)
  let receiver_pool_name = process.new_name(constants.receiver_pool)

  let navigator_sup_spec =
    navigator_sup.start_supervisor(
      coordinates_store_name,
      navigator_name,
      distances_cache_name,
    )

  process.sleep(1000)

  let warehouse_sup_spec =
    warehouse_sup.start_supervisor(
      receiver_pool_name,
      deliverator_pool_name,
      coordinates_store_name,
      distances_cache_name,
      navigator_name,
    )

  process.sleep(1000)

  let assert Ok(_overmind) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(navigator_sup_spec)
    |> static_supervisor.add(warehouse_sup_spec)
    |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
    |> static_supervisor.start()

  let receiver_pool_subject = process.named_subject(receiver_pool_name)
  let deliverator_pool_subject = process.named_subject(deliverator_pool_name)
  let coordinates_store_subject = process.named_subject(coordinates_store_name)
  let distances_cache_subject = process.named_subject(distances_cache_name)
  let navigator_subject = process.named_subject(navigator_name)

  let random_packages = package.random_packages(constants.random_packages_size)
  receiver.receive_packages(
    receiver_pool_subject,
    deliverator_pool_subject,
    coordinates_store_subject,
    distances_cache_subject,
    navigator_subject,
    random_packages,
  )
}
