import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

const batch_size = 5

pub type DeliveratorPoolMessage {
  ReceivePackages(
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
    packages: List(#(String, String)),
  )

  DeliveratorSuccess(
    deliverator_subject: process.Subject(DeliveratorMessage),
    package: #(String, String),
  )

  DeliveratorRestart(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  )
}

type DeliveratorStatus {
  Busy
  Idle
}

fn handle_pool_message(
  state: #(
    List(#(String, String)),
    dict.Dict(process.Subject(DeliveratorMessage), DeliveratorStatus),
    dict.Dict(#(String, String), process.Subject(DeliveratorMessage)),
  ),
  message,
) {
  let #(packages_queue, status_tracker, package_tracker) = state

  case message {
    ReceivePackages(deliverator_pool_subject, packages) -> {
      let available_deliverators =
        status_tracker
        |> dict.fold(from: [], with: fn(acc, deliverator_subject, status) {
          case status {
            Busy -> acc
            Idle -> [deliverator_subject, ..acc]
          }
        })

      let updated_queue =
        packages
        |> list.fold(from: packages_queue, with: fn(acc, package) {
          acc |> list.append([package])
        })

      case available_deliverators {
        // if all busy, add to queue and continue
        [] -> {
          actor.continue(#(updated_queue, status_tracker, package_tracker))
        }
        // if one available, update state and send to deliverator
        [deliverator_subject, ..] -> {
          let #(batch, sliced_queue) =
            updated_queue
            |> list.index_fold(from: #([], []), with: fn(acc, package, idx) {
              let #(batch, sliced_queue) = acc
              case idx < batch_size {
                True -> #([package, ..batch], sliced_queue)
                False -> #(batch, sliced_queue |> list.append([package]))
              }
            })

          let updated_package_tracker =
            batch
            |> list.fold(from: package_tracker, with: fn(acc, package) {
              acc |> dict.insert(package, deliverator_subject)
            })

          let updated_status_tracker =
            status_tracker
            |> dict.fold(
              from: dict.new(),
              with: fn(acc, deliverator_subject_, status) {
                case deliverator_subject == deliverator_subject_ {
                  True -> acc |> dict.insert(deliverator_subject_, Busy)
                  False -> acc |> dict.insert(deliverator_subject_, status)
                }
              },
            )

          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            batch,
          )

          actor.continue(#(
            sliced_queue,
            updated_status_tracker,
            updated_package_tracker,
          ))
        }
      }
    }

    DeliveratorRestart(deliverator_subject, deliverator_pool_subject) -> {
      let updated_status_tracker =
        status_tracker
        |> dict.fold(
          from: dict.new(),
          with: fn(acc, deliverator_subject_, status) {
            case deliverator_subject == deliverator_subject_ {
              True -> acc |> dict.insert(deliverator_subject_, Idle)
              False -> acc |> dict.insert(deliverator_subject_, status)
            }
          },
        )

      case packages_queue {
        // if no packages to deliver, update status and continue
        [] -> {
          actor.continue(#([], updated_status_tracker, package_tracker))
        }
        // if packages need to be delivered,
        _ -> {
          // check if any packages were assigned that were not delivered
          let undelivered =
            package_tracker
            |> dict.fold(from: [], with: fn(acc, package, deliverator_subject_) {
              case deliverator_subject == deliverator_subject_ {
                True -> [package, ..acc]
                False -> acc
              }
            })
            |> list.take(batch_size)

          case undelivered {
            // all assigned were delivered by its previous incarnation 
            [] -> {
              actor.continue(#(
                packages_queue,
                updated_status_tracker,
                package_tracker,
              ))
            }
            // remainder to be delivered by new incarnation
            remainder -> {
              send_to_deliverator(
                deliverator_subject,
                deliverator_pool_subject,
                remainder,
              )
              actor.continue(#(
                packages_queue,
                updated_status_tracker,
                package_tracker,
              ))
            }
          }
        }
      }
    }

    DeliveratorSuccess(deliverator_subject, package) -> {
      todo
    }
  }
}

pub fn new_pool(
  name: process.Name(DeliveratorPoolMessage),
  deliverator_names: List(process.Name(DeliveratorMessage)),
) {
  let status_tracker =
    deliverator_names
    |> list.fold(from: dict.new(), with: fn(acc, deliverator_name) {
      acc
      |> dict.insert(process.named_subject(deliverator_name), Idle)
    })
  let package_tracker = dict.new()
  let state = #([], status_tracker, package_tracker)

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

// Deliverator
pub type DeliveratorMessage {
  DeliverPackages(
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
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
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
) -> Nil {
  case packages {
    [] -> Nil
    [package, ..rest] -> {
      make_delivery()
      //   deliverator_success(receiver_subject, package)
      let #(package_id, content) = package
      io.println("Delivering: " <> package_id <> "\t" <> content)
      deliver(rest, deliverator_pool_subject)
    }
  }
}

fn handle_deliverator_message(
  state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackages(deliverator_pool_subject, packages) -> {
      deliver(packages, deliverator_pool_subject)
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
  let pid = case process.named(name) {
    Error(_) -> "pid not found"
    Ok(pid) -> string.inspect(pid)
  }
  io.println("Deliverator started: " <> pid)

  actor.new([])
  |> actor.on_message(handle_deliverator_message)
  |> actor.named(name)
  |> actor.start
}

pub fn send_to_deliverator(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  packages: List(#(String, String)),
) -> Nil {
  io.println("Deliverator received these packages: ")
  packages
  |> list.each(fn(package) {
    let #(package_id, content) = package
    io.println("\t" <> "id: " <> package_id <> "\t" <> "content: " <> content)
  })

  actor.send(
    deliverator_subject,
    DeliverPackages(deliverator_pool_subject, packages),
  )
}
