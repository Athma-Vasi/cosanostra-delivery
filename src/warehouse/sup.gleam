import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import warehouse/subs

fn start_deliverator(
  deliverator_name: process.Name(subs.DeliveratorMessage),
  receiver_name: process.Name(subs.ReceiverMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let receiver_subject = process.named_subject(receiver_name)

    subs.deliverator_restart(receiver_subject, deliverator_subject)
    subs.new_deliverator(deliverator_name)
  }
}

// fn start_deliverator(
//   name: process.Name(deliverator.DeliveratorMessage),
//   receiver_name: process.Name(receiver.ReceiverMessage),
//   deliverator_monitor_name: process.Name(
//     deliverator_monitor.DeliveratorMonitorMessage,
//   ),
// ) {
//   fn() {
//     let deliverator_subject = process.named_subject(name)
//     let receiver_subject = process.named_subject(receiver_name)
//     let deliverator_monitor_subject =
//       process.named_subject(deliverator_monitor_name)
//     // receiver.deliverator_restart(receiver_subject, deliverator_subject)
//     deliverator_monitor.deliverator_restart(
//       deliverator_monitor_subject,
//       deliverator_subject,
//       receiver_subject,
//     )

//     deliverator.new(name)
//   }
// }

// fn start_deliverator_monitor(
//   name: process.Name(deliverator_monitor.DeliveratorMonitorMessage),
// ) {
//   fn() { deliverator_monitor.new(name) }
// }

// create a fn with restart counter so first start is below
// and next starts trigger receiver message
fn start_receiver(name: process.Name(subs.ReceiverMessage)) {
  fn() { subs.new_receiver(name) }
}

pub fn start_supervisor(
  deliverator_name: process.Name(subs.DeliveratorMessage),
  receiver_name: process.Name(subs.ReceiverMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervision.worker(start_receiver(receiver_name)))
  |> static_supervisor.add(
    supervision.worker(start_deliverator(deliverator_name, receiver_name)),
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
