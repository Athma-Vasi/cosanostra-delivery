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

        // else give available deliverators a batch of packages
        deliverator_subjects -> {
          let batches = updated_queue |> list.sized_chunk(into: batch_size)

          let #(updated_status_tracker, updated_package_tracker) =
            deliverator_subjects
            |> list.index_fold(
              from: #(status_tracker, package_tracker),
              with: fn(acc, deliverator_subject, index) {
                let #(status_tracker, package_tracker) = acc

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

                #(updated_status_tracker, updated_package_tracker)
              },
            )

          let sliced_queue =
            deliverator_subjects
            |> list.index_fold(
              from: [],
              with: fn(acc, _deliverator_subject, index) {
                let batch =
                  batches
                  |> list.index_fold(from: [], with: fn(batch_acc, curr, idx) {
                    case index == idx {
                      True -> curr
                      False -> batch_acc
                    }
                  })

                case batch {
                  [] -> acc
                  batch -> {
                    let sliced_queue =
                      batch
                      |> list.fold(
                        from: updated_queue,
                        with: fn(queue_acc, package_from_batch) {
                          queue_acc
                          |> list.filter(fn(package_in_queue) {
                            package_in_queue != package_from_batch
                          })
                        },
                      )
                    sliced_queue
                  }
                }
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

    DeliveratorRestart(deliverator_subject, deliverator_pool_subject) -> {
      let updated_status_tracker =
        status_tracker
        |> dict.upsert(update: deliverator_subject, with: fn(_status) { Idle })

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

          let updated_state = #(
            packages_queue,
            updated_status_tracker,
            package_tracker,
          )

          case undelivered {
            // all assigned were delivered by its previous incarnation 
            [] -> {
              actor.continue(updated_state)
            }
            // remainder to be delivered by new incarnation
            remainder -> {
              send_to_deliverator(
                deliverator_subject,
                deliverator_pool_subject,
                remainder,
              )
              actor.continue(updated_state)
            }
          }
        }
      }
    }

    DeliveratorSuccess(deliverator_subject, package) -> {
      // remove delivered package from tracker
      let updated_package_tracker = package_tracker |> dict.delete(package)

      case packages_queue {
        // all packages delivered, update state and continue
        [] -> {
          let updated_status_tracker =
            status_tracker
            |> dict.upsert(update: deliverator_subject, with: fn(_status) {
              Idle
            })

          actor.continue(#([], updated_status_tracker, updated_package_tracker))
        }

        packages -> {
          todo
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
