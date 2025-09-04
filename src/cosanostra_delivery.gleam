import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import simplifile

import postal_code/sup

pub fn main() -> Nil {
  let test_geoid = 56_001_962_700
  let test_lat = 41.3021863
  let test_long = -105.6324812
  let store_sup_subject = sup.start_supervisor()
  let #(latitude, longitude) =
    sup.get_coordinates(store_sup_subject, test_geoid)

  io.println(
    "lat"
    <> float.to_string(latitude)
    <> "\t"
    <> "long"
    <> float.to_string(longitude),
  )
  Nil
}
