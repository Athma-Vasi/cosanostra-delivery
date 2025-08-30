import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/pair
import postal_code/data_parser
import postal_code/store

pub fn main() -> Nil {
  // let parser = data_parser.new()
  // let data = data_parser.parse(parser)
  // data
  // |> dict.each(fn(key, tuple) {
  //   let lat = pair.first(tuple)
  //   let long = pair.second(tuple)
  //   io.println(
  //     int.to_string(key) <> float.to_string(lat) <> float.to_string(long),
  //   )
  // })
  let store_actor = store.new()
  let #(latitude, longitude) =
    store.get_coordinates(store_actor, 56_001_962_700)
  io.println(float.to_string(latitude) <> "\t" <> float.to_string(longitude))
}
