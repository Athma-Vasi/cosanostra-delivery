import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp

const batch_size = 5

const max_pool_limit = 10

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

  //   DeliveratorRestart(
  //     deliverator_subject: process.Subject(DeliveratorMessage),
  //     deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  //   )
  StopDeliverator(deliverator_subject: process.Subject(DeliveratorMessage))
}

pub type DeliveratorStatus {
  Busy
  Idle
}

type DeliveratorsTracker =
  dict.Dict(
    process.Subject(DeliveratorMessage),
    #(DeliveratorStatus, timestamp.Timestamp, List(#(String, String))),
  )

type PackageQueue =
  List(#(String, String))

type DeliveratorPoolState =
  #(PackageQueue, DeliveratorsTracker)

fn batch_and_slice_queue(package_queue, batch_size) {
  package_queue
  |> list.index_fold(from: #([], []), with: fn(acc, package, index) {
    let #(batch, sliced_queue) = acc
    case index < batch_size {
      True -> #([package, ..batch], sliced_queue)
      False -> #(batch, sliced_queue |> list.append([package]))
    }
  })
}

fn send_message_and_update_tracker(
  deliverators_tracker: DeliveratorsTracker,
  package_queue: PackageQueue,
  deliverator_pool_subject,
) -> #(PackageQueue, DeliveratorsTracker) {
  deliverators_tracker
  |> dict.fold(
    from: #(package_queue, deliverators_tracker),
    with: fn(acc, deliverator_subject, tracking_info) {
      let #(package_queue, deliverators_tracker) = acc
      let #(status, _deliverator_start_time, _packages) = tracking_info

      case status {
        Busy -> #(package_queue, deliverators_tracker)
        Idle -> {
          let #(batch, sliced_queue) =
            batch_and_slice_queue(package_queue, batch_size)

          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.insert(deliverator_subject, #(
              Busy,
              timestamp.system_time(),
              batch,
            ))

          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            batch,
          )

          #(sliced_queue, updated_deliverators_tracker)
        }
      }
    },
  )
}

fn create_deliverators(
  deliverators_tracker: DeliveratorsTracker,
  amount: Int,
) -> DeliveratorsTracker {
  case amount == 0 {
    True -> deliverators_tracker

    False -> {
      let assert Ok(deliverator) = new_deliverator()
      let deliverator_subject = deliverator.data
      let updated =
        deliverators_tracker
        |> dict.insert(
          deliverator_subject,
          #(Idle, timestamp.system_time(), []),
        )

      create_deliverators(updated, amount - 1)
    }
  }
}

fn handle_pool_message(
  state: DeliveratorPoolState,
  message: DeliveratorPoolMessage,
) {
  // Dict(deliverator, #(status, deliverator start time, packages))
  let #(package_queue, deliverators_tracker) = state

  case message {
    ReceivePackages(deliverator_pool_subject:, packages:) -> {
      // insert packages into queue
      let updated_queue =
        packages
        |> list.fold(from: package_queue, with: fn(acc, package) {
          acc |> list.append([package])
        })

      let current_deliverators_count = dict.size(deliverators_tracker)

      // check tracker to see if more deliverators can be started
      case current_deliverators_count < max_pool_limit {
        True -> {
          // start few deliverators 
          let new_deliverators_count =
            max_pool_limit - current_deliverators_count

          let #(sliced_queue, updated_deliverators_tracker) =
            create_deliverators(deliverators_tracker, new_deliverators_count)
            |> send_message_and_update_tracker(
              package_queue,
              deliverator_pool_subject,
            )

          actor.continue(#(sliced_queue, updated_deliverators_tracker))
        }

        // pool limit reached, wait for returning deliverators
        False -> {
          actor.continue(#(updated_queue, deliverators_tracker))
        }
      }
    }

    PackageDelivered(deliverator_subject:, delivered_package:) -> {
      let updated_deliverators_tracker =
        deliverators_tracker
        |> dict.upsert(
          update: deliverator_subject,
          with: fn(tracking_info_maybe) {
            case tracking_info_maybe {
              option.None -> {
                #(Busy, timestamp.system_time(), [])
              }
              option.Some(tracking_info) -> {
                let #(status, deliverator_start_time, packages) = tracking_info
                #(
                  status,
                  deliverator_start_time,
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

    DeliveratorSuccess(deliverator_subject:, deliverator_pool_subject:) -> {
      todo
    }

    StopDeliverator(deliverator_subject:) -> {
      todo
    }
  }
}

pub fn new_pool(name: process.Name(DeliveratorPoolMessage)) {
  let state = #([], dict.new())

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
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
      //   package_delivered(deliverator_pool_subject, package)

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
      //   deliverator_success(deliverator_subject, deliverator_pool_subject)
      actor.continue(state)
    }
  }
}

pub fn new_deliverator() -> Result(
  actor.Started(process.Subject(DeliveratorMessage)),
  actor.StartError,
) {
  actor.new([])
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
