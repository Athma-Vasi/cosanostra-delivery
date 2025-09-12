import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import warehouse/package
import warehouse/receiver
import warehouse/sup

pub fn start() -> Nil {
  let receiver_name = process.new_name(constants.receiver)
  let deliverator_name = process.new_name(constants.deliverator)
  let deliverator_monitor_name = process.new_name(constants.deliverator_monitor)

  let sup_spec =
    sup.start_supervisor(
      deliverator_name,
      receiver_name,
      deliverator_monitor_name,
    )
  let assert Ok(_warehouse_manager) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(sup_spec)
    |> static_supervisor.start()

  let random_batch = package.random_batch(3)
  let receiver_subject = process.named_subject(receiver_name)
  let deliverator_subject = process.named_subject(deliverator_name)
  receiver.receive_packages(receiver_subject, deliverator_subject, random_batch)

  Nil
}
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
