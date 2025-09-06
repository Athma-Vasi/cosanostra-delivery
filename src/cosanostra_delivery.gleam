import gleam/erlang/process
import gleam/float
import gleam/io
import postal_code/store
import postal_code/sup

pub fn main() -> Nil {
  let test_geoid = 56_001_962_700
  let _test_lat = 41.3021863
  let _test_long = -105.6324812
  let store_name = process.new_name("parser_store")
  let navigator_name = process.new_name("navigator")
  // let cache_name = process.new_name("cache")
  let #(store_subject, navigator_subject) =
    sup.start_supervisor(store_name, navigator_name)
  let #(latitude, longitude) = store.get_coordinates(store_subject, test_geoid)

  io.println(
    "lat: "
    <> float.to_string(latitude)
    <> "\t"
    <> "long: "
    <> float.to_string(longitude),
  )
  Nil
}
