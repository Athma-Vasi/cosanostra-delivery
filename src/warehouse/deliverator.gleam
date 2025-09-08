import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/actor

pub type DeliveratorMessage {
  DeliverPackages(
    // reply_with: process.Subject(Bool),
    packages: List(#(String, String)),
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

fn deliver_helper(packages: List(#(String, String))) -> Nil {
  case packages {
    [] -> Nil
    [top, ..rest] -> {
      let #(package_id, content) = top
      io.println(
        "Deliverator: " <> package_id <> "\t" <> "delivering " <> content,
      )
      make_delivery()
      //   actor.send(receiver_subject)
      deliver_helper(rest)
    }
  }
}

fn deliver(packages: List(#(String, String))) -> Nil {
  deliver_helper(packages)
}

fn handle_message(
  state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackages(packages) -> {
      deliver(packages)
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

pub fn receive(
  packages: List(#(String, String)),
  subject: process.Subject(DeliveratorMessage),
) -> Nil {
  actor.send(subject, DeliverPackages(packages))
}
