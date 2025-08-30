import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import postal_code/data_parser

const timeout: Int = 5000

pub type StoreMessage {
  GetCoordinates(reply_with: Subject(#(Float, Float)), geoid: Int)
}

fn handle_message(state, message: StoreMessage) {
  case message {
    GetCoordinates(client, geoid) -> {
      let parser = data_parser.new()
      let data = data_parser.parse(parser)
      let #(latitude, longitude) =
        data |> dict.get(geoid) |> result.unwrap(#(0.0, 0.0))

      actor.send(client, #(latitude, longitude))
      actor.continue(state)
    }
  }
}

pub fn new() {
  let assert Ok(actor) =
    actor.new([]) |> actor.on_message(handle_message) |> actor.start
  actor.data
}
