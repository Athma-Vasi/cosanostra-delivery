import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import warehouse/package
import warehouse/pool
import warehouse/receiver
import warehouse/sup

pub fn start() -> Nil {
  let deliverator_pool_name = process.new_name(constants.deliverator_pool)
  let receiver_pool_name = process.new_name(constants.receiver_pool)
  let coordinates_store_name = process.new_name(constants.coordinates_store)
  let distances_cache_name = process.new_name(constants.distances_cache)
  let navigator_name = process.new_name(constants.navigator)

  let sup_spec =
    sup.start_supervisor(
      receiver_pool_name,
      deliverator_pool_name,
      coordinates_store_name,
      distances_cache_name,
      navigator_name,
    )

  let assert Ok(_overmind) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(sup_spec)
    |> static_supervisor.start()

  let _deliverator_pool_subject = process.named_subject(deliverator_pool_name)
  let receiver_pool_subject = process.named_subject(receiver_pool_name)
  let coordinates_store_subject = process.named_subject(coordinates_store_name)
  let distances_cache_subject = process.named_subject(distances_cache_name)
  let navigator_subject = process.named_subject(navigator_name)

  process.sleep(100)
  let random_packages = package.random_packages(constants.random_packages_size)
  let deliverator_pool_subject = process.named_subject(deliverator_pool_name)
  receiver.receive_packages(
    receiver_pool_subject,
    deliverator_pool_subject,
    coordinates_store_subject,
    distances_cache_subject,
    navigator_subject,
    random_packages,
  )

  Nil
}
//
//
// pub fn temp(){

//   let store_name = process.new_name("parser_store")
//   let navigator_name = process.new_name("navigator")
//   let cache_name = process.new_name("cache")

//   let sup_spec = sup.start_supervisor(store_name, navigator_name, cache_name)
//   let assert Ok(_overmind) =
//     static_supervisor.new(static_supervisor.OneForOne)
//     |> static_supervisor.add(sup_spec)
//     |> static_supervisor.start()

//   let store_subject = process.named_subject(store_name)
//   let navigator_subject = process.named_subject(navigator_name)
//   let cache_subject = process.named_subject(cache_name)

//   let distance =
//     navigator.get_distance(
//       navigator_subject,
//       56_001_962_700,
//       56_045_951_300,
//       store_subject,
//       cache_subject,
//     )

//   distance |> float.to_string |> io.println
// }
