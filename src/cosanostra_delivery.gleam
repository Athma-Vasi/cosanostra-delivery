import gleam/float
import gleam/io
import postal_code/sup

pub fn main() -> Nil {
  let test_geoid = 56_001_962_700
  let _test_lat = 41.3021863
  let _test_long = -105.6324812
  let store_sup_subject = sup.start_supervisor()
  let #(latitude, longitude) =
    sup.get_coordinates(store_sup_subject, test_geoid)

  io.println(
    "lat: "
    <> float.to_string(latitude)
    <> "\t"
    <> "long: "
    <> float.to_string(longitude),
  )
  Nil
}
