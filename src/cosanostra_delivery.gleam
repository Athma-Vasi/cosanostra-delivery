import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/pair
import postal_code/data_parser

pub fn main() -> Nil {
  let parser = data_parser.new()
  let data = data_parser.parse(parser)
  data
  |> dict.each(fn(key, tuple) {
    let lat = pair.first(tuple)
    let long = pair.second(tuple)
    io.println(key <> lat <> long)
  })
}
