import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import warehouse/deliverator
import warehouse/deliverator_monitor
import warehouse/receiver

fn start_deliverator(
  name: process.Name(deliverator.DeliveratorMessage),
  receiver_name: process.Name(receiver.ReceiverMessage),
  deliverator_monitor_name: process.Name(
    deliverator_monitor.DeliveratorMonitorMessage,
  ),
) {
  fn() {
    let deliverator_subject = process.named_subject(name)
    let receiver_subject = process.named_subject(receiver_name)
    let deliverator_monitor_subject =
      process.named_subject(deliverator_monitor_name)
    // receiver.deliverator_restart(receiver_subject, deliverator_subject)
    deliverator_monitor.deliverator_restart(
      deliverator_monitor_subject,
      deliverator_subject,
      receiver_subject,
    )
    deliverator.new(name)
  }
}

fn start_deliverator_monitor(
  name: process.Name(deliverator_monitor.DeliveratorMonitorMessage),
) {
  fn() { deliverator_monitor.new(name) }
}

// create a fn with restart counter so first start is below
// and next starts trigger receiver message
fn start_receiver(name: process.Name(receiver.ReceiverMessage)) {
  fn() { receiver.new(name) }
}

pub fn start_supervisor(
  deliverator_name: process.Name(deliverator.DeliveratorMessage),
  receiver_name: process.Name(receiver.ReceiverMessage),
  deliverator_monitor_name: process.Name(
    deliverator_monitor.DeliveratorMonitorMessage,
  ),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervision.worker(start_receiver(receiver_name)))
  |> static_supervisor.add(
    supervision.worker(start_deliverator_monitor(deliverator_monitor_name)),
  )
  |> static_supervisor.add(
    supervision.worker(start_deliverator(
      deliverator_name,
      receiver_name,
      deliverator_monitor_name,
    )),
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
