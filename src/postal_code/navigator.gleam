import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import postal_code/store

const timeout: Int = 5000

pub type NavigatorMessage {
  GetDistance(
    reply_with: process.Subject(Int),
    from: Int,
    to: Int,
    store_subject: process.Subject(store.StoreMessage),
  )
}

fn handle_message(state: List(Nil), message: NavigatorMessage) {
  case message {
    GetDistance(client, from, to, store_subject) -> {
      todo
    }
  }
}

pub fn new(
  name: process.Name(NavigatorMessage),
) -> Result(actor.Started(process.Subject(NavigatorMessage)), actor.StartError) {
  actor.new([])
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn get_distance(
  subject: process.Subject(NavigatorMessage),
  from: Int,
  to: Int,
  store_subject: process.Subject(store.StoreMessage),
) {
  actor.call(subject, timeout, GetDistance(_, from, to, store_subject))
}
