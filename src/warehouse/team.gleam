import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
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

  PackageDelivered(package: #(String, String))

  DeliveratorSuccess(
    deliverator_subject: process.Subject(DeliveratorMessage),
    deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  )
  //   DeliveratorRestart(
  //     deliverator_subject: process.Subject(DeliveratorMessage),
  //     deliverator_pool_subject: process.Subject(DeliveratorPoolMessage),
  //   )
}

pub type DeliveratorStatus {
  Busy
  Idle
}

type DeliveratorPoolState =
  #(
    List(#(String, String)),
    dict.Dict(
      process.Subject(DeliveratorMessage),
      #(DeliveratorStatus, timestamp.Timestamp, List(#(String, String))),
    ),
  )

fn handle_pool_message(state: DeliveratorPoolState, message) {
  // Dict(deliverator, #(status, deliverator start time, packages))
  let #(packages_queue, deliverators_tracker) = state

  case message {
    ReceivePackages(deliverator_pool_subject, packages) -> {
      // insert packages into queue
      let updated_queue =
        packages
        |> list.fold(from: packages_queue, with: fn(acc, package) {
          acc |> list.append([package])
        })

      let current_deliverators_count = dict.size(deliverators_tracker)

      // check tracker to see if more deliverators can be started
      case current_deliverators_count < max_pool_limit {
        True -> {
          // start few deliverators 
          let updated_deliverators_tracker =
            create_deliverators(
              deliverators_tracker,
              max_pool_limit - current_deliverators_count,
            )

          // iterate through and find the newly created idle ones
          let available =
            updated_deliverators_tracker
            |> dict.fold(from: [], with: fn(acc, deliverator_subject, tuple) {
              let #(status, _deliverator_start_time, _packages) = tuple

              case status {
                Busy -> acc
                Idle -> [deliverator_subject, ..acc]
              }
            })

          let batches = updated_queue |> list.sized_chunk(into: batch_size)
          let #(sliced_queue, updated_deliverators_tracker) =
            available
            |> list.index_fold(
              from: #([], updated_deliverators_tracker),
              with: fn(acc, deliverator_subject, index) {
                let #(packages_queue, updated_deliverators_tracker) = acc

                let batch =
                  batches
                  |> list.index_fold(from: [], with: fn(batch_acc, curr, idx) {
                    case index == idx {
                      True -> curr
                      False -> batch_acc
                    }
                  })

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
              },
            )

          actor.continue(#(updated_queue, updated_deliverators_tracker))
        }

        // pool limit reached, wait for returning deliverators
        False -> {
          actor.continue(#(updated_queue, deliverators_tracker))
        }
      }
    }

    PackageDelivered(package) -> {
      todo
    }

    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject) -> {
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

type MonitorMessage {
  ProcessDown(process.Down)
}

pub fn create_deliverators(
  deliverators_tracker: dict.Dict(
    process.Subject(DeliveratorMessage),
    #(DeliveratorStatus, timestamp.Timestamp, List(#(String, String))),
  ),
  amount: Int,
) {
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
