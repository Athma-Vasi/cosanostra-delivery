import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

// Receiver 

pub type ReceiverMessage {
  ReceivePackages(
    deliverator_subject: process.Subject(DeliveratorMessage),
    receiver_subject: process.Subject(ReceiverMessage),
    packages: List(#(String, String)),
  )

  DeliveratorSuccess(package: #(String, String))

  DeliveratorRestart(
    deliverator_subject: process.Subject(DeliveratorMessage),
    receiver_subject: process.Subject(ReceiverMessage),
  )
}

fn handle_receiver_message(
  state: #(
    dict.Dict(#(String, String), process.Subject(DeliveratorMessage)),
    Int,
  ),
  message: ReceiverMessage,
) {
  let #(package_tracker, deliverator_restarts) = state

  case message {
    ReceivePackages(deliverator_subject, receiver_subject, packages) -> {
      io.println(
        "Received " <> packages |> list.length |> int.to_string <> " packages",
      )
      send_to_deliverator(deliverator_subject, receiver_subject, packages)
      let updated =
        packages
        |> list.fold(from: package_tracker, with: fn(acc, package) {
          acc |> dict.insert(package, deliverator_subject)
        })
      actor.continue(#(updated, deliverator_restarts))
    }

    DeliveratorSuccess(package) -> {
      let updated = package_tracker |> dict.delete(package)

      updated
      |> dict.each(fn(key, _value) {
        let #(package_id, content) = key
        io.println("DeliveratorSuccess: " <> package_id <> content)
      })
      actor.continue(#(updated, deliverator_restarts))
    }

    DeliveratorRestart(deliverator_subject, receiver_subject) -> {
      case deliverator_restarts == 0 {
        // if just starting, wait for packages,
        True -> Nil
        // else send packages belonging to newly restarted deliverator
        False -> {
          let rest_packages =
            package_tracker
            |> dict.fold(from: [], with: fn(acc, package, some_subject) {
              case some_subject == deliverator_subject {
                True -> [package, ..acc]
                False -> acc
              }
            })

          send_to_deliverator(
            deliverator_subject,
            receiver_subject,
            rest_packages,
          )
        }
      }

      io.println(
        "Deliverator restarts: " <> int.to_string(deliverator_restarts),
      )
      actor.continue(#(package_tracker, deliverator_restarts + 1))
    }
  }
}

pub fn new_receiver(
  name: process.Name(ReceiverMessage),
) -> Result(actor.Started(process.Subject(ReceiverMessage)), actor.StartError) {
  io.println("Receiver started")
  actor.new(#(dict.new(), 0))
  |> actor.on_message(handle_receiver_message)
  |> actor.named(name)
  |> actor.start
}

pub fn receive_packages(
  deliverator_subject: process.Subject(DeliveratorMessage),
  receiver_subject: process.Subject(ReceiverMessage),
  packages: List(#(String, String)),
) -> Nil {
  io.println("Receiver received packages")
  actor.send(
    receiver_subject,
    ReceivePackages(deliverator_subject, receiver_subject, packages),
  )
}

pub fn deliverator_success(
  receiver_subject: process.Subject(ReceiverMessage),
  package: #(String, String),
) {
  io.println("Receiver received deliverator success")
  actor.send(receiver_subject, DeliveratorSuccess(package))
}

pub fn deliverator_restart(
  receiver_subject: process.Subject(ReceiverMessage),
  deliverator_subject: process.Subject(DeliveratorMessage),
) -> Nil {
  io.println("Receiver received deliverator restart")
  process.sleep(100)
  actor.send(
    receiver_subject,
    DeliveratorRestart(deliverator_subject, receiver_subject),
  )
}

// Deliverator

pub type DeliveratorMessage {
  DeliverPackages(
    receiver_subject: process.Subject(ReceiverMessage),
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

fn deliver(
  packages: List(#(String, String)),
  receiver_subject: process.Subject(ReceiverMessage),
) -> Nil {
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
      deliverator_success(receiver_subject, package)
      deliver(rest, receiver_subject)
    }
  }
}

fn handle_deliverator_message(
  state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackages(receiver_subject, packages) -> {
      deliver(packages, receiver_subject)
      actor.continue(state)
    }
  }
}

pub fn new_deliverator(
  name: process.Name(DeliveratorMessage),
) -> Result(
  actor.Started(process.Subject(DeliveratorMessage)),
  actor.StartError,
) {
  actor.new([])
  |> actor.on_message(handle_deliverator_message)
  |> actor.named(name)
  |> actor.start
}

pub fn send_to_deliverator(
  deliverator_subject: process.Subject(DeliveratorMessage),
  receiver_subject: process.Subject(ReceiverMessage),
  packages: List(#(String, String)),
) -> Nil {
  io.println("Deliverator has received packages")
  actor.send(deliverator_subject, DeliverPackages(receiver_subject, packages))
}
