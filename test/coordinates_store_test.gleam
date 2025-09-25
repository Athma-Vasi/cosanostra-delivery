import gleam/erlang/process
import navigator/coordinates_store

pub fn coordinates_store_test() {
  let coordinates_store_name = process.new_name("parser_coordinates_store")
  let assert Ok(_coordinates_store) =
    coordinates_store.new(coordinates_store_name)
  let coordinates_store_subject = process.named_subject(coordinates_store_name)
  let #(lat, long) =
    coordinates_store.get_coordinates(coordinates_store_subject, 56_001_962_800)

  assert lat != 0.0 && lat == 41.3212371
  assert long != 0.0 && long == -105.6279544
}
