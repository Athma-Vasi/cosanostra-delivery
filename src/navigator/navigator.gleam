import gleam/erlang/process
import gleam/float
import gleam/otp/actor
import gleam/result
import gleam_community/maths
import navigator/coordinates_store
import navigator/distances_cache

// km of great circle (Terra)
const radius = 6371.0

const timeout = 5000

pub type NavigatorSubject =
  process.Subject(NavigatorMessage)

type NavigatorState =
  #(
    coordinates_store.CoordinateStoreSubject,
    distances_cache.DistancesCacheSubject,
  )

pub type NavigatorMessage {
  GetDistance(reply_with: process.Subject(Float), from: Int, to: Int)
}

fn degrees_to_radians(degrees: Float) -> Float {
  degrees *. { 3.14159 /. 180.0 }
}

fn calculate_distance(from: #(Float, Float), to: #(Float, Float)) -> Float {
  let #(lat1, long1) = from
  let #(lat2, long2) = to

  let lat_diff = degrees_to_radians(lat2 -. lat1)
  let long_diff = degrees_to_radians(long2 -. long1)

  let lat1 = degrees_to_radians(lat1)
  let lat2 = degrees_to_radians(lat2)

  let cos_lat1 = maths.cos(lat1)
  let cos_lat2 = maths.cos(lat2)

  let sin_lat_diff_sq =
    maths.sin(lat_diff /. 2.0) |> float.power(2.0) |> result.unwrap(0.0)
  let sin_long_diff_sq =
    maths.sin(long_diff /. 2.0) |> float.power(2.0) |> result.unwrap(0.0)
  let a = sin_lat_diff_sq +. { cos_lat1 *. cos_lat2 *. sin_long_diff_sq }
  let c =
    2.0
    *. maths.atan2(
      float.square_root(a) |> result.unwrap(0.0),
      float.square_root(1.0 -. a) |> result.unwrap(0.0),
    )

  radius *. c |> maths.round_to_nearest(2)
}

fn handle_message(
  state: NavigatorState,
  message: NavigatorMessage,
) -> actor.Next(NavigatorState, a) {
  let #(coordinates_store_subject, distances_cache_subject) = state
  case message {
    GetDistance(client, from, to) -> {
      let distance = case
        distances_cache.get_distance(distances_cache_subject, from, to)
      {
        Error(Nil) -> {
          let here =
            coordinates_store.get_coordinates(coordinates_store_subject, from)
          let there =
            coordinates_store.get_coordinates(coordinates_store_subject, to)
          calculate_distance(here, there)
        }
        Ok(dist) -> dist
      }

      actor.send(client, distance)
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(NavigatorMessage),
  coordinates_store_name: process.Name(coordinates_store.StoreMessage),
  distances_cache_name: process.Name(distances_cache.CacheMessage),
) -> Result(actor.Started(process.Subject(NavigatorMessage)), actor.StartError) {
  let state = #(
    process.named_subject(coordinates_store_name),
    process.named_subject(distances_cache_name),
  )
  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn get_distance(
  subject: process.Subject(NavigatorMessage),
  from: Int,
  to: Int,
) -> Float {
  actor.call(subject, timeout, GetDistance(_, from, to))
}
