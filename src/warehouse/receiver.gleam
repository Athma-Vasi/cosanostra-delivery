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
  DeliveratorSuccess(package: #(String, String))
  DeliveratorFailure(
    deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
  )
}

fn assign_packages(
  state,
  packages: List(#(String, String)),
  deliverator_subject: process.Subject(deliverator.DeliveratorMessage),
) -> dict.Dict(
  #(String, String),
  process.Subject(deliverator.DeliveratorMessage),
) {
  packages
  |> list.fold(from: state, with: fn(acc, package) {
    acc |> dict.insert(package, deliverator_subject)
  })
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
      deliverator.receive(packages, deliverator_subject)
      let updated = assign_packages(state, packages, deliverator_subject)
      actor.continue(updated)
    }

    DeliveratorSuccess(package) -> {
      actor.continue(state |> dict.delete(package))
    }

    DeliveratorFailure(deliverator_subject) -> {
      let packages =
        state
        |> dict.fold(from: [], with: fn(acc, package, _deliverator_subject) {
          [package, ..acc]
        })

      deliverator.receive(packages, deliverator_subject)
      actor.continue(state)
    }
    // DeliveratorFailure(new_deliverator_subject) -> {
    //   let #(packages, updated) =
    //     state
    //     |> dict.fold(
    //       from: #([], dict.new()),
    //       with: fn(acc, package, _old_deliverator_subject) {
    //         let #(packages, updated) = acc
    //         #(
    //           [package, ..packages],
    //           updated |> dict.insert(package, new_deliverator_subject),
    //         )
    //       },
    //     )
    //   deliverator.receive(packages, new_deliverator_subject)
    //   actor.continue(updated)
    // }
  }
}

pub fn new(
  name: process.Name(ReceiverMessage),
) -> Result(actor.Started(process.Subject(ReceiverMessage)), actor.StartError) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}
