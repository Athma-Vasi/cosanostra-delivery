import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import gleam/result

const timeout = 5000

pub type CacheMessage {
  SetDistance(distance: Float, from: Float, to: Float)
  GetDistance(reply_with: process.Subject(Float), from: Float, to: Float)
}

fn handle_message(
  state: dict.Dict(#(Float, Float), Float),
  message: CacheMessage,
) {
  case message {
    SetDistance(distance, from, to) -> {
      let updated = state |> dict.insert(#(from, to), distance)
      actor.continue(updated)
    }
    GetDistance(client, from, to) -> {
      let distance = state |> dict.get(#(from, to)) |> result.unwrap(0.0)
      actor.send(client, distance)
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(CacheMessage),
) -> Result(actor.Started(process.Subject(CacheMessage)), actor.StartError) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn get_distance_cached(
  subject: process.Subject(CacheMessage),
  from: Float,
  to: Float,
) {
  actor.call(subject, timeout, GetDistance(_, from, to))
}

pub fn set_distance_cached(
  subject: process.Subject(CacheMessage),
  distance: Float,
  from: Float,
  to: Float,
) {
  actor.send(subject, SetDistance(distance, from, to))
}
