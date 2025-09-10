import gleam/erlang/port
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/string
import warehouse/deliverator
import warehouse/receiver

pub type DeliveratorMonitorMessage {
  PortDown(
    monitor: process.Monitor,
    port: port.Port,
    reason: process.ExitReason,
  )
  ProcessDown(
    monitor: process.Monitor,
    pid: process.Pid,
    reason: process.ExitReason,
  )
}

fn handle_message(
  state: #(
    process.Subject(receiver.ReceiverMessage),
    process.Subject(deliverator.DeliveratorMessage),
  ),
  message: DeliveratorMonitorMessage,
) {
  case message {
    PortDown(_, _, _) -> {
      io.println("Port down")
      actor.continue(state)
    }
    ProcessDown(_monitor, pid, reason) -> {
      // wait for newly restarted deliverator
      process.sleep(1000)
      let #(receiver_subject, deliverator_subject) = state
      let assert Ok(deliverator_name) =
        process.subject_name(deliverator_subject)
      let assert Ok(deliverator_pid) = process.named(deliverator_name)
      let _deliverator_monitor = process.monitor(deliverator_pid)

      let reason = case reason {
        process.Abnormal(_) -> "exited abnormally"
        process.Killed -> "was stopped"
        process.Normal -> "exited normally"
      }

      io.println(
        "Monitor report: process " <> string.inspect(pid) <> " " <> reason,
      )

      // deliverator subject is passed to receiver upon exit (crash) so it can 
      // send remaining packages to the newly created deliverator
      receiver.deliverator_failure(receiver_subject, deliverator_subject)
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(DeliveratorMonitorMessage),
  deliverator_name: process.Name(deliverator.DeliveratorMessage),
  receiver_name: process.Name(receiver.ReceiverMessage),
) -> Result(
  actor.Started(process.Subject(DeliveratorMonitorMessage)),
  actor.StartError,
) {
  // give deliverator time to start
  process.sleep(1000)

  // receiver subject is used as state because the PortDown/ProcessDown are
  // built in type constructors
  let receiver_subject = process.named_subject(receiver_name)
  let deliverator_subject = process.named_subject(deliverator_name)
  let state = #(receiver_subject, deliverator_subject)
  let actor =
    actor.new(state)
    |> actor.named(name)
    |> actor.on_message(handle_message)
    |> actor.start

  // after this actor has started, monitor deliverator
  let assert Ok(deliverator_pid) = process.named(deliverator_name)
  let _deliverator_monitor = process.monitor(deliverator_pid)
  actor
}
