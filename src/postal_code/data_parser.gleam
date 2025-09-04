import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile

const timeout: Int = 5000

pub type ParserMessage {
  Parse(reply_with: Subject(Dict(Int, #(Float, Float))))
}

fn handle_message(state, message: ParserMessage) {
  case message {
    Parse(client) -> {
      let contents = case
        simplifile.read(from: "src/data/wyoming_census_gazetteer.txt")
      {
        Ok(contents) -> {
          let coordinate_table =
            contents
            |> string.split(on: "\n")
            |> list.drop(up_to: 1)
            |> list.fold(from: dict.new(), with: fn(table, row) {
              let parsed =
                row
                |> string.trim
                |> string.split(on: "\t")
                |> list.index_fold(from: [], with: fn(array, item, index) {
                  case index == 1 || index == 6 || index == 7 {
                    True -> array |> list.append([item])
                    False -> array
                  }
                })

              case parsed {
                [geoid, latitude, longitude] -> {
                  let geoid = int.parse(geoid) |> result.unwrap(0)
                  let latitude = float.parse(latitude) |> result.unwrap(0.0)
                  let longitude = float.parse(longitude) |> result.unwrap(0.0)
                  table
                  |> dict.insert(geoid, #(latitude, longitude))
                }
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
    actor.new([]) |> actor.on_message(handle_message) |> actor.start
  actor.data
}

pub fn parse(parcel: Subject(ParserMessage)) {
  actor.call(parcel, timeout, Parse)
}
