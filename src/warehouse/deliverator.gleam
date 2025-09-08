import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/actor
import warehouse/receiver

pub type DeliveratorMessage {
  DeliverPackages(
    // reply_with: process.Subject(Bool),
    packages: dict.Dict(String, String),
    receiver_subject: process.Subject(receiver.ReceiverMessage),
  )
}

fn maybe_crash() -> Nil {
  let crash_factor = int.random(100)
  io.println("Crash factor: " <> int.to_string(crash_factor))
  case crash_factor > 60 {
    True -> {
      io.println("Uncle Enzo is not pleased... delivery deadline missed!")
      panic
    }
    False -> Nil
  }
}

fn make_delivery() -> Nil {
  let rand_timer = int.random(3000)
  process.sleep(rand_timer)
  maybe_crash()
}

fn deliver_helper(
  packages: List(#(String, String)),
  receiver_subject: process.Subject(receiver.ReceiverMessage),
) -> Nil {
  case packages {
    [] -> Nil
    [top, ..rest] -> {
      let #(package_id, content) = top
      io.println(
        "Deliverator: " <> package_id <> "\t" <> "delivering " <> content,
      )
      make_delivery()
      //   actor.send(receiver_subject)
      deliver_helper(rest, receiver_subject)
    }
  }
}

fn deliver(
  packages: dict.Dict(String, String),
  receiver_subject: process.Subject(receiver.ReceiverMessage),
) -> Nil {
  dict.to_list(packages) |> deliver_helper(receiver_subject)
}

fn handle_message(
  state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackages(packages, receiver_subject) -> {
      deliver(packages, receiver_subject)
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(DeliveratorMessage),
) -> Result(
  actor.Started(process.Subject(DeliveratorMessage)),
  actor.StartError,
) {
  actor.new([])
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}
