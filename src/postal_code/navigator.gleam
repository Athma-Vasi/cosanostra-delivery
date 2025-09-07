import gleam/erlang/process
import gleam/float
import gleam/otp/actor
import gleam/result
import gleam_community/maths
import postal_code/cache
import postal_code/store

// km of great circle (Terra)
const radius = 6371.0

const timeout = 5000

pub type NavigatorMessage {
  GetDistance(
    reply_with: process.Subject(Float),
    from: Int,
    to: Int,
    store_subject: process.Subject(store.StoreMessage),
    cache_subject: process.Subject(cache.CacheMessage),
  )
}

fn degrees_to_radians(degrees: Float) -> Float {
  degrees *. { 3.14159 /. 180.0 }
}

fn calculate_distance(from: #(Float, Float), to: #(Float, Float)) -> Float {
  let #(lat1, long1) = from
  let #(lat2, long2) = to

  let lat_diff = degrees_to_radians(lat2 -. lat1)
  let long_diff = degrees_to_radians(long2 -. long1)

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
  state: List(Nil),
  message: NavigatorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    GetDistance(client, from, to, store_subject, cache_subject) -> {
      let distance = case cache.get_distance(cache_subject, from, to) {
        0.0 -> {
          let here = store.get_coordinates(store_subject, from)
          let there = store.get_coordinates(store_subject, to)
          calculate_distance(here, there)
        }
        dist -> dist
      }

      actor.send(client, distance)
      actor.continue(state)
    }
  }
}

pub fn new(
  name: process.Name(NavigatorMessage),
) -> Result(actor.Started(process.Subject(NavigatorMessage)), actor.StartError) {
  actor.new([])
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn get_distance(
  subject: process.Subject(NavigatorMessage),
  from: Int,
  to: Int,
  store_subject: process.Subject(store.StoreMessage),
  cache_subject: process.Subject(cache.CacheMessage),
) -> Float {
  actor.call(subject, timeout, GetDistance(
    _,
    from,
    to,
    store_subject,
    cache_subject,
  ))
}
