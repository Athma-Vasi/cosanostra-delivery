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

    // sent every time deliverator starts
    // receiver actor keeps track of restarts in its state
    subs.deliverator_restart(receiver_subject, deliverator_subject)
    subs.new_deliverator(deliverator_name)
  }
}

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
