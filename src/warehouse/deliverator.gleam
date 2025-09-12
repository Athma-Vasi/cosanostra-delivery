import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
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
      panic as "panic! at the warehouse"
    }
    False -> Nil
  }
}

fn make_delivery() -> Nil {
  let rand_timer = int.random(3000)
  process.sleep(rand_timer)
  maybe_crash()
}

fn deliver(packages: List(#(String, String))) -> Nil {
  packages
  |> list.each(fn(package) {
    let #(id, content) = package
    io.println("id: " <> id <> "content: " <> content)
  })

  case packages {
    [] -> Nil
    [package, ..rest] -> {
      let #(package_id, content) = package
      io.println(
        "Deliverator " <> "delivering " <> package_id <> "\t" <> content,
      )
      make_delivery()
      deliver(rest)
    }
  }
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
  this_subject: process.Subject(DeliveratorMessage),
  packages: List(#(String, String)),
) -> Nil {
  io.println("Deliverator has received packages")
  actor.send(this_subject, DeliverPackages(packages))
}
