import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import warehouse/deliverator

pub type ReceiverMessage {
  ReceivePackages(
    packages: List(#(String, String)),
    deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
  )
}

fn handle_message(
  state: List(Nil),
  message: ReceiverMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    ReceivePackages(packages, deliverator_subject) -> {
      io.println(
        "Received " <> packages |> list.length |> int.to_string <> " packages",
      )
      deliverator.receive(packages, deliverator_subject)
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(ReceiverMessage),
) -> Result(actor.Started(process.Subject(ReceiverMessage)), actor.StartError) {
  actor.new([])
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}
