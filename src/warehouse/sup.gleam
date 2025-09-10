import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import warehouse/deliverator
import warehouse/deliverator_monitor
import warehouse/receiver

fn start_deliverator(name: process.Name(deliverator.DeliveratorMessage)) {
  fn() { deliverator.new(name) }
}

fn start_receiver(name: process.Name(receiver.ReceiverMessage)) {
  fn() { receiver.new(name) }
}

fn start_deliverator_monitor(
  name: process.Name(deliverator_monitor.DeliveratorMonitorMessage),
  deliverator_name: process.Name(deliverator.DeliveratorMessage),
  receiver_name: process.Name(receiver.ReceiverMessage),
) {
  fn() { deliverator_monitor.new(name, deliverator_name, receiver_name) }
}

pub fn start_supervisor(
  deliverator_name: process.Name(deliverator.DeliveratorMessage),
  receiver_name: process.Name(receiver.ReceiverMessage),
  deliverator_monitor_name: process.Name(
    deliverator_monitor.DeliveratorMonitorMessage,
  ),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(
    supervision.worker(start_deliverator(deliverator_name)),
  )
  |> static_supervisor.add(supervision.worker(start_receiver(receiver_name)))
  |> static_supervisor.add(
    supervision.worker(start_deliverator_monitor(
      deliverator_monitor_name,
      deliverator_name,
      receiver_name,
    )),
  )
  |> static_supervisor.restart_tolerance(intensity: 3, period: 1000)
  |> static_supervisor.supervised()
}
