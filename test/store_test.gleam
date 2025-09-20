import gleam/erlang/process
import navigator/coordinates_store

pub fn coordinates_store_test() {
  let coordinates_store_name = process.new_name("parser_coordinates_store")
  let assert Ok(_coordinates_store) =
    coordinates_store.new(coordinates_store_name)
}
