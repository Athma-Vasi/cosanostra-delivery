import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/otp/actor

type Parcel =
  #(String, String)

type GeoId =
  Int

type Package =
  #(GeoId, Parcel)

type PackageQueue =
  List(Package)

type ReceiverPoolSubject =
  process.Subject(ReceiverPoolMessage)

type ReceiverSubject =
  process.Subject(ReceiverMessage)

pub opaque type ReceiverPoolMessage {
  ReceivePackages(
    receiver_pool_subject: ReceiverPoolSubject,
    packages: List(Package),
  )

  PathFound(receiver_subject: ReceiverSubject, packages: List(Package))

  ReceiverSuccess(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
  )

  ReceiverRestart(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
  )
}

pub opaque type ReceiverState {
  Busy
  Idle
}

type ReceiversTracker =
  dict.Dict(ReceiverSubject, ReceiverState)

type UnorderedPackages =
  List(Int)

type OrderedPackages =
  List(Int)

type Distance =
  Int

type MemoizedPaths =
  dict.Dict(UnorderedPackages, #(OrderedPackages, Distance))

type ReceiverPoolState =
  #(PackageQueue, ReceiversTracker, MemoizedPaths)

fn handle_pool_message(state: ReceiverPoolState, message: ReceiverPoolMessage) {
  case message {
    ReceivePackages(receiver_pool_subject, packages) -> {
      todo
    }

    PathFound(receiver_subject, packages) -> {
      todo
    }

    ReceiverSuccess(receiver_subject, receiver_pool_subject) -> {
      todo
    }

    ReceiverRestart(receiver_subject, receiver_pool_subject) -> {
      todo
    }
  }
}

pub fn new_pool(
  name: process.Name(ReceiverPoolMessage),
  receiver_names: List(process.Name(ReceiverMessage)),
) {
  let receivers_tracker =
    receiver_names
    |> list.fold(from: dict.new(), with: fn(acc, receiver_name) {
      acc |> dict.insert(process.named_subject(receiver_name), Idle)
    })
  let package_queue = []
  let memoized_paths = dict.new()
  let state = #(package_queue, receivers_tracker, memoized_paths)

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub opaque type ReceiverMessage {
  CalculateShortestPath(
    receiver_subject: ReceiverPoolSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    packages: List(Package),
  )
}

fn generate_paths_permutations(packages) {
  todo
}

fn handle_receiver_message(state: List(Nil), message: ReceiverMessage) {
  case message {
    CalculateShortestPath(receiver_subject, receiver_pool_subject, packages) -> {
      todo
    }
  }
}

pub fn new_receiver(name: process.Name(ReceiverMessage)) {
  actor.new([])
  |> actor.named(name)
  |> actor.on_message(handle_receiver_message)
  |> actor.start
}
