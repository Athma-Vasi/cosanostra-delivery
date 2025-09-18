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

pub opaque type ReceiverPoolMessage {
  ReceivePackages(
    receiver_pool_subject: process.Subject(ReceiverPoolMessage),
    packages: List(Package),
  )

  ReceiverSuccess

  ReceiverRestart
}

pub opaque type ReceiverState {
  Busy
  Idle
}

type ReceiverPoolState =
  #(
    PackageQueue,
    dict.Dict(process.Subject(ReceiverMessage), ReceiverState),
    dict.Dict(List(Int), List(Int)),
  )

fn handle_pool_message(state: ReceiverPoolState, message: ReceiverPoolMessage) {
  todo
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
  CalculateShortestPath
}

fn handle_receiver_message(state: List(Nil), message: ReceiverMessage) {
  todo
}

pub fn new_receiver(name: process.Name(ReceiverMessage)) {
  actor.new([])
  |> actor.named(name)
  |> actor.on_message(handle_receiver_message)
  |> actor.start
}
