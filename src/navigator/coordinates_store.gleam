import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/result
import navigator/gazetteer_parser

const timeout = 5000

pub type CoordinateStoreSubject =
  process.Subject(StoreMessage)

pub opaque type StoreMessage {
  GetCoordinates(reply_with: process.Subject(#(Float, Float)), geoid: Int)
  GetGeoids(reply_with: process.Subject(List(Int)))
}

fn handle_message(state: dict.Dict(Int, #(Float, Float)), message: StoreMessage) {
  case message {
    GetCoordinates(client, geoid) -> {
      let #(latitude, longitude) =
        state |> dict.get(geoid) |> result.unwrap(#(0.0, 0.0))

      actor.send(client, #(latitude, longitude))
      actor.continue(state)
    }

    GetGeoids(client) -> {
      actor.send(client, dict.keys(state))
      actor.continue(state)
    }
  }
}

pub fn new(name: process.Name(StoreMessage)) {
  let state = gazetteer_parser.new() |> gazetteer_parser.parse
  echo "Loaded " <> int.to_string(dict.size(state)) <> " coordinates"

  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn get_coordinates(subject: process.Subject(StoreMessage), geoid: Int) {
  actor.call(subject, timeout, GetCoordinates(_, geoid))
}

pub fn get_geoids(subject: process.Subject(StoreMessage)) {
  actor.call(subject, timeout, GetGeoids)
}
