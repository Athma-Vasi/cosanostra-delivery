import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import simplifile

const timeout: Int = 5000

pub type ParserMessage {
  Parse(reply_with: Subject(String))
}

fn handle_parser_message(state, message: ParserMessage) {
  case message {
    Parse(client) -> {
      let contents =
        simplifile.read(from: "src/data/wyoming_census_gazeteer.txt")
        |> result.unwrap("error")

      actor.send(client, contents)
      actor.continue(state)
    }
  }
}

pub fn new() {
  let assert Ok(actor) =
    actor.new([]) |> actor.on_message(handle_parser_message) |> actor.start
  actor.data
}

pub fn parse(parcel: Subject(ParserMessage)) {
  actor.call(parcel, timeout, Parse)
}
