import constants
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/string
import warehouse/deliverator
import warehouse/receiver

pub type DeliveratorMonitorMessage {
  DeliveratorSuccess(package: #(String, String))
  DeliveratorRestart(
    deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
    receiver_subject: process.Subject(receiver.ReceiverMessage),
  )
}

fn handle_message(
  state: Int,
  // deliverator restarts
  message: DeliveratorMonitorMessage,
) {
  case message {
    DeliveratorSuccess(package) -> {
      //   let updated = package_tracker |> dict.delete(package)

      //   updated
      //   |> dict.each(fn(key, _value) {
      //     let #(package_id, content) = key
      //     io.println("DeliveratorSuccess: " <> package_id <> content)
      //   })

      //   actor.continue(#(updated, deliverator_restarts))
      io.println("deliverator success handled")
      actor.continue(state)
    }
    DeliveratorRestart(deliverator_subject, receiver_subject) -> {
      let updated = state + 1
      receiver.deliverator_restart(
        receiver_subject,
        deliverator_subject,
        updated,
      )
      actor.continue(updated)
    }
  }
}

pub fn new(name: process.Name(DeliveratorMonitorMessage)) {
  io.println("Monitor started")
  // give deliverator time to start
  process.sleep(100)

  actor.new(0)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn deliverator_success(
  this_subject: process.Subject(DeliveratorMonitorMessage),
  package: #(String, String),
) {
  io.println("DeliveratorMonitor received deliverator success")
  actor.send(this_subject, DeliveratorSuccess(package))
}

pub fn deliverator_restart(
  this_subject: process.Subject(DeliveratorMonitorMessage),
  deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
  receiver_subject: process.Subject(receiver.ReceiverMessage),
) {
  io.println("DeliveratorMonitor received deliverator restart")
  actor.send(
    this_subject,
    DeliveratorRestart(deliverator_subject, receiver_subject),
  )
}
