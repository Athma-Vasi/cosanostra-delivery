import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import warehouse/package
import warehouse/pool
import warehouse/sup

pub fn start() -> Nil {
  let deliverator_pool_name = process.new_name(constants.deliverator_pool)
  let deliverator1_name = process.new_name(constants.deliverator1)
  let deliverator2_name = process.new_name(constants.deliverator2)
  let deliverator3_name = process.new_name(constants.deliverator3)
  let deliverator4_name = process.new_name(constants.deliverator4)
  let deliverator5_name = process.new_name(constants.deliverator5)

  let sup_spec =
    sup.start_supervisor(
      deliverator1_name,
      deliverator2_name,
      deliverator3_name,
      deliverator4_name,
      deliverator5_name,
      deliverator_pool_name,
    )

  let assert Ok(_warehouse_manager) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(sup_spec)
    |> static_supervisor.start()

  let random_batch = package.random_batch(10)
  let deliverator_pool_subject = process.named_subject(deliverator_pool_name)
  pool.receive_packages(deliverator_pool_subject, random_batch)

  Nil
}
// pub fn temp(){

// let receiver_name = process.new_name(constants.receiver)
// let deliverator_name = process.new_name(constants.deliverator)

// let sup_spec = sup.start_supervisor(deliverator_name, receiver_name)
// let assert Ok(_warehouse_manager) =
//   static_supervisor.new(static_supervisor.OneForOne)
//   |> static_supervisor.add(sup_spec)
//   |> static_supervisor.start()

// let random_batch = package.random_batch(10)
// let receiver_subject = process.named_subject(receiver_name)
// let deliverator_subject = process.named_subject(deliverator_name)
// subs.receive_packages(deliverator_subject, receiver_subject, random_batch)

//
//

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
