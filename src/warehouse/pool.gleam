import constants
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import warehouse/utils

type DeliveratorPoolSubject =
  process.Subject(DeliveratorPoolMessage)

type DeliveratorSubject =
  process.Subject(DeliveratorMessage)

pub opaque type DeliveratorPoolMessage {
  ReceivePackages(
    deliverator_pool_subject: DeliveratorPoolSubject,
    packages: List(Package),
  )

  PackageDelivered(
    deliverator_subject: DeliveratorSubject,
    delivered_package: Package,
  )

  DeliveratorSuccess(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
  )

  DeliveratorRestart(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
  )
}

pub opaque type DeliveratorStatus {
  Busy
  Idle
}

type DeliveratorsTracker =
  dict.Dict(DeliveratorSubject, #(DeliveratorStatus, Int, List(Package)))

type Parcel =
  #(String, String)

type GeoId =
  Int

type Package =
  #(GeoId, Parcel)

type PackageQueue =
  List(Package)

type Distance =
  Float

type DeliveratorShipment =
  List(#(GeoId, Parcel, Distance))

type DeliveratorPoolState =
  #(PackageQueue, DeliveratorsTracker)

fn remove_delivered_package(
  deliverators_tracker,
  deliverator_subject,
  delivered_package,
) -> DeliveratorsTracker {
  deliverators_tracker
  |> dict.upsert(update: deliverator_subject, with: fn(tracking_info_maybe) {
    case tracking_info_maybe {
      option.None -> #(Busy, 0, [])

      option.Some(tracking_info) -> {
        let #(status, restarts, packages) = tracking_info
        let filtered =
          packages
          |> list.filter(keeping: fn(package_in_tracker) {
            package_in_tracker != delivered_package
          })

        #(status, restarts, filtered)
      }
    }
  })
}

fn find_available_deliverators(
  deliverators_tracker,
) -> List(#(DeliveratorSubject, Int)) {
  deliverators_tracker
  |> dict.fold(from: [], with: fn(acc, deliverator_subject, tracking_info) {
    let #(status, restarts, packages) = tracking_info
    case status, packages {
      Idle, [] -> [#(deliverator_subject, restarts), ..acc]

      Idle, _packages | Busy, [] | Busy, _packages -> acc
    }
  })
}

fn send_batches_to_available_deliverators(
  updated_deliverators_tracker: DeliveratorsTracker,
  available_deliverators: List(#(DeliveratorSubject, Int)),
  batches: List(List(Package)),
  deliverator_pool_subject: DeliveratorPoolSubject,
) {
  case available_deliverators, batches {
    [], [] | [], _batches | _available, [] -> updated_deliverators_tracker

    [available, ..rest_availables], [batch, ..rest_batches] -> {
      let #(deliverator_subject, restarts) = available
      send_to_deliverator(deliverator_subject, deliverator_pool_subject, batch)

      send_batches_to_available_deliverators(
        updated_deliverators_tracker
          |> dict.insert(deliverator_subject, #(Busy, restarts, batch)),
        rest_availables,
        rest_batches,
        deliverator_pool_subject,
      )
    }
  }
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
        find_available_deliverators(deliverators_tracker)

      case available_deliverators {
        // if all busy, add to queue and continue
        [] -> actor.continue(#(updated_queue, deliverators_tracker))

        // else "push" available deliverators a batch of packages
        availables -> {
          let #(batches, sliced_queue) =
            utils.batch_and_slice_queue(updated_queue, list.length(availables))

          actor.continue(#(
            sliced_queue,
            send_batches_to_available_deliverators(
              deliverators_tracker,
              available_deliverators,
              batches,
              deliverator_pool_subject,
            ),
          ))
        }
      }
    }

    PackageDelivered(deliverator_subject, delivered_package) -> {
      let updated_deliverators_tracker =
        remove_delivered_package(
          deliverators_tracker,
          deliverator_subject,
          delivered_package,
        )

      let packages_remaining_count =
        updated_deliverators_tracker
        |> dict.fold(
          from: 0,
          with: fn(acc, _deliverator_subject, tracking_info) {
            let #(_status, _restarts, packages) = tracking_info
            acc + list.length(packages)
          },
        )

      io.println(
        "_-_ "
        <> int.to_string(packages_remaining_count)
        <> " packages remaining",
      )

      actor.continue(#(package_queue, updated_deliverators_tracker))
    }

    // all assigned packages (batch) to this deliverator have been delivered
    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject) -> {
      let #(_status, restarts, _packages) =
        deliverators_tracker
        |> dict.get(deliverator_subject)
        |> result.unwrap(or: #(Idle, 0, []))

      // check if any packages remain in queue
      case package_queue {
        // all packages currently assigned to deliverators
        [] ->
          // update tracker and continue
          actor.continue(#(
            [],
            deliverators_tracker
              |> dict.insert(deliverator_subject, #(Idle, restarts, [])),
          ))

        // packages remain in queue
        packages_to_deliver -> {
          // each successful deliverator "pulls" a batch from the queue
          let #(batches, sliced_queue) =
            utils.batch_and_slice_queue(packages_to_deliver, 1)
          let batch = utils.get_first_batch(batches)
          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            batch,
          )
          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.insert(deliverator_subject, #(Busy, restarts, batch))

          actor.continue(#(sliced_queue, updated_deliverators_tracker))
        }
      }
    }

    DeliveratorRestart(deliverator_subject, deliverator_pool_subject) -> {
      let #(_status, restarts, undelivered_packages) =
        deliverators_tracker
        |> dict.get(deliverator_subject)
        |> result.unwrap(or: #(Idle, 0, []))

      case restarts == 0, undelivered_packages {
        // first incarnation of deliverator
        True, [] | True, _undelivered ->
          // update tracker and continue
          actor.continue(#(
            package_queue,
            deliverators_tracker
              |> dict.insert(deliverator_subject, #(Idle, restarts + 1, [])),
          ))

        // reincarnated with all assigned packages delivered
        False, [] -> {
          // check if any packages remain in queue
          case package_queue {
            // queue is empty, all packages delivered
            [] ->
              actor.continue(#(
                [],
                deliverators_tracker
                  |> dict.insert(deliverator_subject, #(Idle, restarts + 1, [])),
              ))

            // packages in queue need to be delivered
            packages_in_queue -> {
              // each reincarnated deliverator "pulls" a batch from the queue
              let #(batches, sliced_queue) =
                utils.batch_and_slice_queue(packages_in_queue, 1)
              let batch = utils.get_first_batch(batches)
              send_to_deliverator(
                deliverator_subject,
                deliverator_pool_subject,
                batch,
              )
              let updated_deliverators_tracker =
                deliverators_tracker
                |> dict.insert(deliverator_subject, #(Busy, restarts + 1, batch))

              actor.continue(#(sliced_queue, updated_deliverators_tracker))
            }
          }
        }

        // reincarnated with assigned packages undelivered 
        False, undelivered -> {
          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.insert(deliverator_subject, #(
              Busy,
              restarts + 1,
              undelivered,
            ))

          // send remaining packages to deliverator to try again
          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            undelivered,
          )

          actor.continue(#(package_queue, updated_deliverators_tracker))
        }
      }
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
  deliverator_pool_subject: DeliveratorPoolSubject,
  packages: List(Package),
) {
  actor.send(
    deliverator_pool_subject,
    ReceivePackages(deliverator_pool_subject, packages),
  )
}

fn package_delivered(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  delivered_package: Package,
) {
  actor.send(
    deliverator_pool_subject,
    PackageDelivered(deliverator_subject, delivered_package),
  )
}

pub fn deliverator_restart(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorRestart(deliverator_subject, deliverator_pool_subject),
  )
}

fn deliverator_success(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject),
  )
}

// Deliverator
pub opaque type DeliveratorMessage {
  DeliverPackages(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
    packages: List(Package),
  )
}

fn maybe_crash() -> Nil {
  let crash_factor = int.random(100)
  io.println("Crash factor: " <> int.to_string(crash_factor))
  case crash_factor > constants.crash_factor_limit {
    True -> {
      io.println("Uncle Enzo is not pleased... delivery deadline missed!")
      panic as "Panic! At The Warehouse"
    }
    False -> Nil
  }
}

fn make_delivery() -> Nil {
  let rand_timer = int.random(1000)
  process.sleep(rand_timer)
  maybe_crash()
}

fn deliver(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  packages: List(Package),
) -> Nil {
  case packages {
    [] -> Nil
    [package, ..rest] -> {
      make_delivery()
      package_delivered(deliverator_subject, deliverator_pool_subject, package)

      // let #(package_id, content) = package
      // io.println(
      //   "Deliverator: "
      //   <> string.inspect(deliverator_subject)
      //   <> " successfully delivered: "
      //   <> package_id
      //   <> "\t"
      //   <> content,
      // )

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
  }
}

pub fn new_deliverator(
  name: process.Name(DeliveratorMessage),
) -> Result(actor.Started(DeliveratorSubject), actor.StartError) {
  actor.new([])
  |> actor.named(name)
  |> actor.on_message(handle_deliverator_message)
  |> actor.start
}

fn send_to_deliverator(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  packages: List(Package),
) -> Nil {
  process.sleep(100)

  // io.println(
  //   "Deliverator: "
  //   <> string.inspect(deliverator_subject)
  //   <> " received these packages: ",
  // )
  // packages
  // |> list.each(fn(package) {
  //   let #(package_id, content) = package
  //   io.println("\t" <> "id: " <> package_id <> "\t" <> "content: " <> content)
  // })

  actor.send(
    deliverator_subject,
    DeliverPackages(deliverator_subject, deliverator_pool_subject, packages),
  )
}
