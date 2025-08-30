import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile

const timeout: Int = 5000

pub type ParserMessage {
  Parse(reply_with: Subject(Dict(String, #(String, String))))
}

fn handle_parser_message(state, message: ParserMessage) {
  case message {
    Parse(client) -> {
      let contents = case
        simplifile.read(from: "src/data/wyoming_census_gazeteer.txt")
      {
        Ok(contents) -> {
          let coordinate_table =
            contents
            |> string.split(on: "\n")
            |> list.drop(up_to: 1)
            |> list.fold(from: dict.new(), with: fn(table, row) {
              let selected =
                row
                |> string.trim
                |> string.split(on: "\t")
                |> list.index_fold(from: [], with: fn(array, item, idx) {
                  case idx == 1 || idx == 6 || idx == 7 {
                    True -> array |> list.append([item])
                    False -> array
                  }
                })

              case selected {
                [geoid, latitude, longitude] ->
                  table |> dict.insert(geoid, #(latitude, longitude))
                _ -> table
              }
            })

          coordinate_table
        }
        Error(_) -> dict.new()
      }

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
