import gleam/dict
import gleam/list
import gleam/result
import navigator/gazetteer_parser

pub fn gazetteer_parser_test() {
  let parser = gazetteer_parser.new()
  let data = gazetteer_parser.parse(parser)
  let #(geoid, #(latitude, longitude)) =
    data |> dict.to_list |> list.first |> result.unwrap(#(0, #(0.0, 0.0)))
  assert geoid != 0 && latitude != 0.0 && longitude != 0.0

  let test_geoid = 56_001_962_700
  let test_lat = 41.3021863
  let test_long = -105.6324812
  let #(latitude, longitude) =
    data |> dict.get(test_geoid) |> result.unwrap(#(0.0, 0.0))
  assert latitude == test_lat && longitude == test_long
}
