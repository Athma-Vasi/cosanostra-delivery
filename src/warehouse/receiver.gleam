import constants
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import postal_code/cache
import postal_code/navigator
import postal_code/store

type Parcel =
  #(String, String)

type GeoId =
  Int

type Package =
  #(GeoId, Parcel)

type PackageQueue =
  List(Package)

pub type ReceiverPoolSubject =
  process.Subject(ReceiverPoolMessage)

pub type ReceiverSubject =
  process.Subject(ReceiverMessage)

pub opaque type ReceiverPoolMessage {
  ReceivePackages(
    receiver_pool_subject: ReceiverPoolSubject,
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    packages: List(Package),
  )

  PathFound(receiver_subject: ReceiverSubject, packages: List(Package))

  ReceiverSuccess(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
  )

  ReceiverRestart(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
  )
}

pub opaque type ReceiverState {
  Busy
  Idle
}

type ReceiversTracker =
  dict.Dict(ReceiverSubject, ReceiverState)

type UnorderedPackages =
  List(Int)

type OrderedPackages =
  List(Int)

type Distance =
  Float

type MemoizedPaths =
  dict.Dict(UnorderedPackages, #(OrderedPackages, Distance))

type ReceiverPoolState =
  #(PackageQueue, ReceiversTracker, MemoizedPaths)

fn handle_pool_message(state: ReceiverPoolState, message: ReceiverPoolMessage) {
  case message {
    ReceivePackages(
      receiver_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      packages,
    ) -> {
      todo
    }

    PathFound(receiver_subject, packages) -> {
      todo
    }

    ReceiverSuccess(receiver_subject, receiver_pool_subject) -> {
      todo
    }

    ReceiverRestart(receiver_subject, receiver_pool_subject) -> {
      todo
    }
  }
}

pub fn new_pool(
  name: process.Name(ReceiverPoolMessage),
  receiver_names: List(process.Name(ReceiverMessage)),
) {
  let receivers_tracker =
    receiver_names
    |> list.fold(from: dict.new(), with: fn(acc, receiver_name) {
      acc |> dict.insert(process.named_subject(receiver_name), Idle)
    })
  let package_queue = []
  let memoized_paths = dict.new()
  let state = #(package_queue, receivers_tracker, memoized_paths)

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub opaque type ReceiverMessage {
  CalculateShortestPath(
    receiver_subject: ReceiverPoolSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    packages: List(Package),
  )
}

// T(n) = O(n!)
// S(n) = O(n * n!)
pub fn generate_geoids_permutations(list: List(Int)) -> List(List(Int)) {
  case list {
    [] -> [[]]

    list ->
      list.flat_map(list, fn(element) {
        // This line is the Gleam equivalent of Elixir's `list -- [element]`.
        // We get the "rest" of the list by deleting the first instance of the current element.
        let rest =
          list
          |> list.filter(keeping: fn(elem) { elem != element })

        // Recursively find all permutations of the remaining elements.
        let sub_permutations = generate_geoids_permutations(rest)

        // Prepend the current element to each sub-permutation to build the full permutations.
        list.map(sub_permutations, fn(p) { [element, ..p] })
      })
  }
}

fn add_home_base_to_paths(paths: List(List(Int))) {
  paths
  |> list.map(with: fn(path) {
    [constants.receiver_home_geoid, ..path]
    |> list.append([constants.receiver_home_geoid])
  })
}

fn create_distance_pairs_helper(
  distance_pairs: List(#(Int, Int)),
  path: List(Int),
  stack: List(Int),
) {
  case path, stack {
    [], [] | [], _stack -> distance_pairs

    // starting, stack is empty
    [geoid, ..rest_geoids], [] ->
      // add geoid to stack and continue
      create_distance_pairs_helper(distance_pairs, rest_geoids, [geoid, ..stack])

    [curr_geoid, ..rest_geoids], [prev_geoid, ..rest_stack] ->
      // take the prev_geoid and current as pair
      // add current to stack and continue
      create_distance_pairs_helper(
        [#(prev_geoid, curr_geoid), ..distance_pairs],
        rest_geoids,
        [curr_geoid, ..rest_stack],
      )
  }
}

fn create_distance_pairs(
  paths: List(List(GeoId)),
) -> List(List(#(GeoId, GeoId))) {
  // paths
  // |> list.fold(from: [], with: fn(acc, path) {
  //   let distance_pairs = create_distance_pairs_helper([], path, [])
  //   [distance_pairs, ..acc]
  // })

  paths
  |> list.map(with: fn(path) { create_distance_pairs_helper([], path, []) })
}

fn compute_total_distances(
  distance_pairs_list: List(List(#(GeoId, GeoId))),
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
) -> List(#(List(#(GeoId, GeoId)), Distance)) {
  distance_pairs_list
  |> list.map(with: fn(distance_pairs) {
    // distance for a permutation of path geoids
    // ex: [ [a, b], [b, c], [c, d], [d, e] ]
    let path_distance =
      distance_pairs
      |> list.fold(from: 0.0, with: fn(acc, distance_pair) {
        let #(from, to) = distance_pair
        let distance =
          navigator.get_distance(
            navigator_subject,
            from,
            to,
            coordinates_store_subject,
            coordinates_cache_subject,
          )

        acc +. distance
      })

    #(distance_pairs, path_distance)
  })
}

fn find_shortest_distance_path(
  path_distance_tuples: List(#(List(#(GeoId, GeoId)), Distance)),
) {
  path_distance_tuples
  |> list.sort(by: fn(path_distance_tuple1, path_distance_tuple2) { todo })
}

fn handle_receiver_message(state: List(Nil), message: ReceiverMessage) {
  case message {
    CalculateShortestPath(
      receiver_subject,
      receiver_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      packages,
    ) -> {
      let #(geoids, geoid_parcel_table) =
        packages
        |> list.fold(from: #([], dict.new()), with: fn(acc, tuple) {
          let #(geoids, geoid_parcel_table) = acc
          let #(geoid, parcel) = tuple

          #([geoid, ..geoids], geoid_parcel_table |> dict.insert(geoid, parcel))
        })

      let permutations = generate_geoids_permutations(geoids)

      actor.continue(state)
    }
  }
}

pub fn new_receiver(name: process.Name(ReceiverMessage)) {
  actor.new([])
  |> actor.named(name)
  |> actor.on_message(handle_receiver_message)
  |> actor.start
}
