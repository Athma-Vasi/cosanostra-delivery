import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import postal_code/navigator
import postal_code/store

fn start_parser(name: process.Name(store.StoreMessage)) {
  fn() { store.new(name) }
}

fn start_navigator(name: process.Name(navigator.NavigatorMessage)) {
  fn() { navigator.new(name) }
}

pub fn start_supervisor(
  store_name: process.Name(store.StoreMessage),
  navigator_name: process.Name(navigator.NavigatorMessage),
) -> #(
  process.Subject(store.StoreMessage),
  process.Subject(navigator.NavigatorMessage),
) {
  let _sup =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(supervision.worker(start_parser(store_name)))
    |> supervisor.add(supervision.worker(start_navigator(navigator_name)))
    |> supervisor.start

  // create and return subjects for names
  let store_subject = process.named_subject(store_name)
  let navigator_subject = process.named_subject(navigator_name)
  #(store_subject, navigator_subject)
}
