import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import postal_code/store

fn start_parser(name: process.Name(store.StoreMessage)) {
  fn() { store.new(name) }
}

pub fn start_supervisor() {
  // generate new name
  let store_name = process.new_name("store")
  let _sup =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(supervision.worker(start_parser(store_name)))
    |> supervisor.start

  // create and return subject for name
  process.named_subject(store_name)
}

const timeout: Int = 5000

pub fn get_coordinates(parcel: process.Subject(store.StoreMessage), geoid: Int) {
  actor.call(parcel, timeout, store.GetCoordinates(_, geoid))
}
