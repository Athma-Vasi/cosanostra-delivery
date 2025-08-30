import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import postal_code/data_parser

pub fn data_parser_test() {
  let parser = data_parser.new()
  let data = data_parser.parse(parser)
  let #(geoid, #(latitude, longitude)) =
    data |> dict.to_list |> list.first |> result.unwrap(#("", #("", "")))

  assert string.length(geoid) != 0
    && string.length(latitude) != 0
    && string.length(longitude) != 0
}
