import gleam/dict
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

  DeliveratorRestart(
    restarts: Int,
    deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
  )
}

fn handle_message(
  state: dict.Dict(
    #(String, String),
    process.Subject(deliverator.DeliveratorMessage),
  ),
  message: ReceiverMessage,
) -> actor.Next(
  dict.Dict(#(String, String), process.Subject(deliverator.DeliveratorMessage)),
  a,
) {
  case message {
    ReceivePackages(packages, deliverator_subject) -> {
      io.println(
        "Received " <> packages |> list.length |> int.to_string <> " packages",
      )
      deliverator.receive(deliverator_subject, packages)
      let updated =
        packages
        |> list.fold(from: state, with: fn(acc, package) {
          acc |> dict.insert(package, deliverator_subject)
        })
      actor.continue(updated)
    }

    DeliveratorRestart(restarts, deliverator_subject) -> {
      case restarts == 0 {
        // if just starting, wait for packages,
        True -> Nil
        // else send packages belonging to newly created deliverator
        False -> {
          let rest_packages =
            state
            |> dict.fold(from: [], with: fn(acc, package, some_subject) {
              case some_subject == deliverator_subject {
                True -> [package, ..acc]
                False -> acc
              }
            })

          deliverator.receive(deliverator_subject, rest_packages)
        }
      }

      io.println("Deliverator restarts: " <> int.to_string(restarts))
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(ReceiverMessage),
) -> Result(actor.Started(process.Subject(ReceiverMessage)), actor.StartError) {
  io.println("Receiver started")
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn receive_packages(
  this_subject: process.Subject(ReceiverMessage),
  deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
  packages: List(#(String, String)),
) -> Nil {
  io.println("Receiver received packages")
  actor.send(this_subject, ReceivePackages(packages, deliverator_subject))
}

pub fn deliverator_restart(
  this_subject: process.Subject(ReceiverMessage),
  deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
  restarts: Int,
) -> Nil {
  process.sleep(1000)
  actor.send(this_subject, DeliveratorRestart(restarts, deliverator_subject))
}
