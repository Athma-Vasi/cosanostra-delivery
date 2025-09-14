import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/string

const batch_size = 5

pub type DeliveratorPoolMessage {
  ReceivePackages(
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
    packages: List(#(String, String)),
  )

  PackageDelivered(package: #(String, String))

  DeliveratorSuccess(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  )

  DeliveratorRestart(deliverator_subject: process.Subject(DeliveratorMessage))
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
      io.println("Received packages: ")
      packages
      |> list.each(fn(package) {
        let #(id, content) = package
        io.println("\t" <> "id: " <> id <> "\t" <> "content: " <> content)
      })

      let available_deliverators =
        status_tracker
        |> dict.fold(from: [], with: fn(acc, deliverator_subject, status) {
          case status {
            Busy -> acc
            Idle -> [deliverator_subject, ..acc]
          }
        })

      io.println("Available deliverators: ")
      available_deliverators
      |> list.each(fn(deliverator) {
        io.println("\t" <> "deliverator:" <> string.inspect(deliverator))
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

        // else give available deliverators a batch of packages
        deliverator_subjects -> {
          let batches = updated_queue |> list.sized_chunk(into: batch_size)

          let #(sliced_queue, updated_status_tracker, updated_package_tracker) =
            deliverator_subjects
            |> list.index_fold(
              from: #(updated_queue, status_tracker, package_tracker),
              with: fn(acc, deliverator_subject, index) {
                let #(packages_queue, status_tracker, package_tracker) = acc

                let batch =
                  batches
                  |> list.index_fold(from: [], with: fn(batch_acc, curr, idx) {
                    case index == idx {
                      True -> curr
                      False -> batch_acc
                    }
                  })

                let updated_package_tracker =
                  batch
                  |> list.fold(
                    from: package_tracker,
                    with: fn(tuple_acc, package_from_batch) {
                      let package_tracker = tuple_acc

                      let updated_package_tracker =
                        package_tracker
                        |> dict.insert(package_from_batch, deliverator_subject)

                      updated_package_tracker
                    },
                  )

                // let updated_status_tracker = case batch {
                //   [] -> status_tracker
                //   _ -> status_tracker |> dict.insert(deliverator_subject, Busy)
                // }
                let updated_status_tracker =
                  status_tracker |> dict.insert(deliverator_subject, Busy)

                let sliced_queue = case batch {
                  [] -> packages_queue
                  batch -> {
                    batch
                    |> list.fold(
                      from: packages_queue,
                      with: fn(queue_acc, package_from_batch) {
                        queue_acc
                        |> list.filter(fn(package_in_queue) {
                          package_in_queue != package_from_batch
                        })
                      },
                    )
                  }
                }

                #(sliced_queue, updated_status_tracker, updated_package_tracker)
              },
            )

          let _nil =
            deliverator_subjects
            |> list.index_fold(
              from: Nil,
              with: fn(acc, deliverator_subject, index) {
                let batch =
                  batches
                  |> list.index_fold(from: [], with: fn(batch_acc, curr, idx) {
                    case index == idx {
                      True -> curr
                      False -> batch_acc
                    }
                  })

                case batch {
                  [] -> Nil
                  batch ->
                    send_to_deliverator(
                      deliverator_subject,
                      deliverator_pool_subject,
                      batch,
                    )
                }

                acc
              },
            )

          actor.continue(#(
            sliced_queue,
            updated_status_tracker,
            updated_package_tracker,
          ))
        }
      }
    }

    PackageDelivered(delivered_package) -> {
      let updated_package_tracker =
        package_tracker
        |> dict.filter(keeping: fn(package_in_tracker, _deliverator_subject) {
          package_in_tracker != delivered_package
        })

      actor.continue(#(packages_queue, status_tracker, updated_package_tracker))
    }

    DeliveratorRestart(deliverator_subject) -> {
      let updated_status_tracker =
        status_tracker
        |> dict.upsert(update: deliverator_subject, with: fn(_status) { Idle })

      actor.continue(#(packages_queue, updated_status_tracker, package_tracker))
    }

    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject) -> {
      case packages_queue {
        // all packages delivered, update state and continue
        [] -> {
          let updated_status_tracker =
            status_tracker
            |> dict.upsert(update: deliverator_subject, with: fn(_status) {
              Idle
            })

          actor.continue(#([], updated_status_tracker, package_tracker))
        }

        packages_to_deliver -> {
          let #(batch, sliced_queue) =
            packages_to_deliver
            |> list.index_fold(from: #([], []), with: fn(acc, package, index) {
              let #(batch, sliced_queue) = acc
              case index < batch_size {
                True -> #([package, ..batch], sliced_queue)
                False -> #(batch, sliced_queue |> list.append([package]))
              }
            })

          let updated_status_tracker =
            status_tracker
            |> dict.upsert(update: deliverator_subject, with: fn(_status) {
              Busy
            })

          let updated_package_tracker =
            batch
            |> list.fold(from: package_tracker, with: fn(acc, package) {
              acc |> dict.insert(package, deliverator_subject)
            })

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

pub fn receive_packages(
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  packages: List(#(String, String)),
) {
  actor.send(
    deliverator_pool_subject,
    ReceivePackages(deliverator_pool_subject:, packages:),
  )
}

fn package_delivered(
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  package: #(String, String),
) {
  actor.send(deliverator_pool_subject, PackageDelivered(package))
}

pub fn deliverator_restart(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
) {
  actor.send(deliverator_pool_subject, DeliveratorRestart(deliverator_subject:))
}

pub fn deliverator_success(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorSuccess(deliverator_subject:, deliverator_pool_subject:),
  )
}

// Deliverator
pub type DeliveratorMessage {
  DeliverPackages(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
    packages: List(#(String, String)),
  )
}

fn maybe_crash() -> Nil {
  let crash_factor = int.random(100)
  io.println("Crash factor: " <> int.to_string(crash_factor))
  case crash_factor > 90 {
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
      package_delivered(deliverator_pool_subject, package)

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
    DeliverPackages(deliverator_subject, deliverator_pool_subject, packages) -> {
      deliver(packages, deliverator_pool_subject)
      deliverator_success(deliverator_subject, deliverator_pool_subject)
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
  io.println("Deliverator started: " <> string.inspect(name))

  actor.new([])
  |> actor.on_message(handle_deliverator_message)
  |> actor.named(name)
  |> actor.start
}

fn send_to_deliverator(
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
    DeliverPackages(deliverator_subject, deliverator_pool_subject, packages),
  )
}
