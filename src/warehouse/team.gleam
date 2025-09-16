import constants
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string

pub type DeliveratorPoolMessage {
  ReceivePackages(
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
    packages: List(#(String, String)),
  )

  PackageDelivered(
    deliverator_subject: process.Subject(DeliveratorMessage),
    delivered_package: #(String, String),
  )

  DeliveratorSuccess(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  )

  DeliveratorRestart(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  )
}

pub type DeliveratorStatus {
  Busy
  Idle
}

type DeliveratorsTracker =
  dict.Dict(
    process.Subject(DeliveratorMessage),
    #(DeliveratorStatus, Int, List(#(String, String))),
  )

type PackageQueue =
  List(#(String, String))

type DeliveratorPoolState =
  #(PackageQueue, DeliveratorsTracker)

// fn send_messages(
//   deliverators_tracker: DeliveratorsTracker,
//   package_queue: PackageQueue,
//   deliverator_pool_subject,
// ) -> #(PackageQueue, DeliveratorsTracker) {
//   deliverators_tracker
//   |> dict.fold(
//     from: #(package_queue, deliverators_tracker),
//     with: fn(acc, deliverator_subject, tracking_info) {
//       let #(package_queue, deliverators_tracker) = acc
//       let #(status, restarts, _packages) = tracking_info

//       case status {
//         Busy -> #(package_queue, deliverators_tracker)
//         Idle -> {
//           let #(batch, sliced_queue) =
//             batch_and_slice_queue(package_queue, constants.batch_size)

//           let updated_deliverators_tracker =
//             deliverators_tracker
//             |> dict.insert(deliverator_subject, #(Busy, restarts, batch))

//           send_to_deliverator(
//             deliverator_subject,
//             deliverator_pool_subject,
//             batch,
//           )

//           #(sliced_queue, updated_deliverators_tracker)
//         }
//       }
//     },
//   )
// }

fn send_remaining_batches(batches, deliverators, deliverator_pool_subject) {
  case batches, deliverators {
    [], [] -> Nil

    [batch, ..rest_batches], [deliverator, ..rest_deliverators] -> {
      send_to_deliverator(deliverator, deliverator_pool_subject, batch)
      send_remaining_batches(
        rest_batches,
        rest_deliverators,
        deliverator_pool_subject,
      )
    }

    // both batches and deliverators must be same size
    _, _ -> Nil
  }
}

fn batch_and_slice_queue_helper(
  batches: List(List(#(String, String))),
  sliced_queue: PackageQueue,
  counter,
  available_deliverators_count,
) {
  case counter == available_deliverators_count {
    True -> #(batches, sliced_queue)

    False -> {
      let batch = sliced_queue |> list.take(up_to: constants.batch_size)
      let rest = sliced_queue |> list.drop(up_to: constants.batch_size)

      batch_and_slice_queue_helper(
        [batch, ..batches],
        rest,
        counter + 1,
        available_deliverators_count,
      )
    }
  }
}

fn batch_and_slice_queue(
  package_queue: PackageQueue,
  available_deliverators_count,
) -> #(List(List(#(String, String))), PackageQueue) {
  batch_and_slice_queue_helper(
    [],
    package_queue,
    0,
    available_deliverators_count,
  )
}

fn handle_pool_message(
  state: DeliveratorPoolState,
  message: DeliveratorPoolMessage,
) {
  let #(package_queue, deliverators_tracker) = state

  case message {
    ReceivePackages(deliverator_pool_subject, packages) -> {
      // insert packages into queue
      let updated_queue =
        packages
        |> list.fold(from: package_queue, with: fn(acc, package) {
          acc |> list.append([package])
        })

      let available_deliverators =
        deliverators_tracker
        |> dict.fold(
          from: [],
          with: fn(acc, deliverator_subject, tracking_info) {
            let #(status, restarts, packages) = tracking_info
            case status, packages {
              Idle, [] -> [#(deliverator_subject, restarts), ..acc]
              _, _ -> acc
            }
          },
        )

      case available_deliverators {
        // if all busy, add to queue and continue
        [] -> actor.continue(#(updated_queue, deliverators_tracker))

        // else give available deliverators a batch of packages
        availables -> {
          let #(batches, sliced_queue) =
            batch_and_slice_queue(updated_queue, list.length(availables))

          let updated_deliverators_tracker =
            availables
            |> list.index_fold(
              from: deliverators_tracker,
              with: fn(acc, tuple, index) {
                let #(deliverator_subject, restarts) = tuple

                let batch =
                  batches
                  |> list.index_fold(from: [], with: fn(batch_acc, batch, idx) {
                    case index == idx {
                      True -> batch
                      False -> batch_acc
                    }
                  })

                send_to_deliverator(
                  deliverator_subject,
                  deliverator_pool_subject,
                  batch,
                )

                acc
                |> dict.insert(deliverator_subject, #(Busy, restarts, batch))
              },
            )

          actor.continue(#(sliced_queue, updated_deliverators_tracker))
        }
      }
    }

    PackageDelivered(deliverator_subject, delivered_package) -> {
      let updated_deliverators_tracker =
        deliverators_tracker
        |> dict.upsert(
          update: deliverator_subject,
          with: fn(tracking_info_maybe) {
            case tracking_info_maybe {
              option.None -> {
                #(Busy, 0, [])
              }
              option.Some(tracking_info) -> {
                let #(status, restarts, packages) = tracking_info
                #(
                  status,
                  restarts,
                  packages
                    |> list.filter(keeping: fn(package_in_tracker) {
                      package_in_tracker != delivered_package
                    }),
                )
              }
            }
          },
        )

      actor.continue(#(package_queue, updated_deliverators_tracker))
    }

    // all assigned packages (batch) have been delivered
    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject) -> {
      // does any packages remain in queue
      case package_queue {
        // all packages currently assigned to deliverators
        [] -> {
          // update tracker and continue
          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.upsert(
              update: deliverator_subject,
              with: fn(tracking_info_maybe) {
                case tracking_info_maybe {
                  option.None -> #(Idle, 0, [])

                  option.Some(tracking_info) -> {
                    let #(_status, restarts, _packages) = tracking_info
                    #(Idle, restarts, [])
                  }
                }
              },
            )

          actor.continue(#([], updated_deliverators_tracker))
        }

        // packages remain in queue
        packages_to_deliver -> {
          // each successful deliverator "pulls" a batch from the queue
          let #(batches, sliced_queue) =
            batch_and_slice_queue(packages_to_deliver, 1)
          // list.take(1) does not narrow the return type
          let batch =
            batches
            |> list.index_fold(from: [], with: fn(acc, batch, index) {
              case index == 0 {
                True -> batch
                False -> acc
              }
            })

          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.upsert(
              update: deliverator_subject,
              with: fn(tracking_info_maybe) {
                case tracking_info_maybe {
                  option.None -> #(Idle, 0, [])

                  option.Some(tracking_info) -> {
                    let #(_status, restarts, _packages) = tracking_info
                    #(Busy, restarts, batch)
                  }
                }
              },
            )

          actor.continue(#(sliced_queue, updated_deliverators_tracker))
        }
      }
    }

    DeliveratorRestart(deliverator_subject, deliverator_pool_subject) -> {
      todo
    }
  }
}

pub fn new_pool(
  name: process.Name(DeliveratorPoolMessage),
  deliverator_names: List(process.Name(DeliveratorMessage)),
) {
  let deliverators_tracker =
    deliverator_names
    |> list.fold(from: dict.new(), with: fn(acc, deliverator_name) {
      acc
      |> dict.insert(process.named_subject(deliverator_name), #(Idle, 0, []))
    })
  let package_queue = []
  let state = #(package_queue, deliverators_tracker)

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
    ReceivePackages(deliverator_pool_subject, packages),
  )
}

fn package_delivered(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  delivered_package: #(String, String),
) {
  actor.send(
    deliverator_pool_subject,
    PackageDelivered(deliverator_subject, delivered_package),
  )
}

pub fn deliverator_restart(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorRestart(deliverator_subject, deliverator_pool_subject),
  )
}

pub fn deliverator_success(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject),
  )
}

// Deliverator
pub type DeliveratorMessage {
  DeliverPackages(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
    packages: List(#(String, String)),
  )

  StopDeliverator
}

fn maybe_crash() -> Nil {
  let crash_factor = int.random(100)
  io.println("Crash factor: " <> int.to_string(crash_factor))
  case crash_factor > 90 {
    True -> {
      io.println("Uncle Enzo is not pleased... delivery deadline missed!")
      panic as "Panic! At The Warehouse"
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
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  packages: List(#(String, String)),
) -> Nil {
  case packages {
    [] -> Nil
    [package, ..rest] -> {
      make_delivery()
      package_delivered(deliverator_subject, deliverator_pool_subject, package)

      let #(package_id, content) = package
      io.println(
        "Deliverator: "
        <> string.inspect(deliverator_subject)
        <> " delivering: "
        <> package_id
        <> "\t"
        <> content,
      )

      deliver(deliverator_subject, deliverator_pool_subject, rest)
    }
  }
}

fn handle_deliverator_message(
  state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackages(deliverator_subject, deliverator_pool_subject, packages) -> {
      deliver(deliverator_subject, deliverator_pool_subject, packages)
      deliverator_success(deliverator_subject, deliverator_pool_subject)
      actor.continue(state)
    }

    StopDeliverator -> {
      actor.stop()
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
  |> actor.named(name)
  |> actor.on_message(handle_deliverator_message)
  |> actor.start
}

fn send_to_deliverator(
  deliverator_subject: process.Subject(DeliveratorMessage),
  deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  packages: List(#(String, String)),
) -> Nil {
  // simulate work over time
  process.sleep(1000)

  io.println(
    "Deliverator: "
    <> string.inspect(deliverator_subject)
    <> " received these packages: ",
  )
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

fn stop_deliverator(
  deliverator_subject: process.Subject(DeliveratorMessage),
) -> Nil {
  actor.send(deliverator_subject, StopDeliverator)
}
