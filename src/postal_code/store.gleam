import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/io
import gleam/otp/actor
import gleam/result
import postal_code/data_parser

pub type StoreMessage {
  GetCoordinates(reply_with: Subject(#(Float, Float)), geoid: Int)
}

fn handle_message(state: Dict(Int, #(Float, Float)), message: StoreMessage) {
  case message {
    GetCoordinates(client, geoid) -> {
      let #(latitude, longitude) =
        state |> dict.get(geoid) |> result.unwrap(#(0.0, 0.0))

      io.println(float.to_string(latitude))
      io.println(float.to_string(longitude))

      actor.send(client, #(latitude, longitude))
      actor.continue(state)
    }
  }
}

pub fn new(name: process.Name(StoreMessage)) {
  let state = data_parser.new() |> data_parser.parse

  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}
