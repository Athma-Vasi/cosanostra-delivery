import constants
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/otp/actor
import postal_code/cache
import postal_code/navigator
import postal_code/store
import warehouse/pool
import warehouse/utils

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
    deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    packages: List(Package),
  )

  PathComputedSuccess(
    receiver_subject: ReceiverSubject,
    packages: List(Package),
  )

  RequestMemoized(receiver_subject: ReceiverSubject, geoids: SortedAscGeoIds)

  // ReceiverSuccess(
  //   receiver_subject: ReceiverSubject,
  //   receiver_pool_subject: ReceiverPoolSubject,
  // )
  ReceiverRestart(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
  )
}

pub opaque type ReceiverState {
  Busy
  Idle
}

type ReceiverRestarts =
  Int

type ReceiversTracker =
  dict.Dict(ReceiverSubject, #(ReceiverState, ReceiverRestarts, List(Package)))

type SortedAscGeoIds =
  List(Int)

type ShortestPath =
  List(#(GeoId, GeoId))

type Distance =
  Float

type MemoizedShortestPathsDistances =
  dict.Dict(SortedAscGeoIds, #(ShortestPath, Distance))

type ReceiverPoolState =
  #(PackageQueue, ReceiversTracker, MemoizedShortestPathsDistances)

pub fn send_batches_to_available_receivers(
  updated_receivers_tracker: ReceiversTracker,
  available_receivers: List(#(ReceiverSubject, Int)),
  batches: List(List(Package)),
  receiver_pool_subject: ReceiverPoolSubject,
) {
  case available_receivers, batches {
    [], [] | [], _batches | _available, [] -> updated_receivers_tracker

    [available, ..rest_availables], [batch, ..rest_batches] -> {
      let #(receiver_subject, restarts) = available
      send_to_receiver(receiver_subject, receiver_pool_subject, batch)

      send_batches_to_available_receivers(
        updated_receivers_tracker
          |> dict.insert(receiver_subject, #(Busy, restarts, batch)),
        rest_availables,
        rest_batches,
        receiver_pool_subject,
      )
    }
  }
}

fn handle_pool_message(state: ReceiverPoolState, message: ReceiverPoolMessage) {
  let #(package_queue, receivers_tracker, memoized_shortest_distances_paths) =
    state

  case message {
    ReceivePackages(
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      packages,
    ) -> {
      let updated_queue = package_queue |> list.append(packages)

      let available_receivers =
        receivers_tracker
        |> dict.fold(from: [], with: fn(acc, receiver_subject, tracking_info) {
          let #(status, restarts, batch) = tracking_info
          case status, batch {
            Idle, [] -> [#(receiver_subject, restarts), ..acc]
            Busy, [] | Busy, _batch | Idle, _batch -> acc
          }
        })

      let #(batches, sliced_queue) =
        utils.batch_and_slice_queue(
          updated_queue,
          list.length(available_receivers),
        )

      // check each batch's geoids to see if we have already computed
      // the shortest distance path
      let #(not_computed_batches, computed_batches) =
        batches
        |> list.fold(from: #([], []), with: fn(acc, batch) {
          let #(not_computed_batches, computed_batches) = acc

          // sort asc the geoids to check memo table
          let sorted_asc_geoids =
            batch
            |> list.map(with: fn(tuple) {
              let #(geoid, _parcel) = tuple
              geoid
            })
            |> list.sort(by: fn(geoid1, geoid2) { int.compare(geoid1, geoid2) })

          case
            memoized_shortest_distances_paths |> dict.get(sorted_asc_geoids)
          {
            // add to batch for computin' by receivers 
            Error(Nil) -> #(
              not_computed_batches |> list.append([batch]),
              computed_batches,
            )

            // if already computed, will be sent to deliverator pool
            Ok(shortest_distance_path) -> #(
              not_computed_batches,
              computed_batches |> list.append([shortest_distance_path]),
            )
          }
        })

      // send computed batches to deliverator pool
      pool.receive_packages(deliverator_pool_subject, [])

      case available_receivers {
        // all receivers currently computin'
        [] ->
          // add to queue and continue
          actor.continue(#(
            updated_queue,
            receivers_tracker,
            memoized_shortest_distances_paths,
          ))

        // else "push" available receivers batches to compute
        availables -> {
          let updated_receivers_tracker =
            send_batches_to_available_receivers(
              receivers_tracker,
              not_computed_batches,
              available_receivers,
              receiver_pool_subject,
              coordinates_store_subject,
              coordinates_cache_subject,
              navigator_subject,
            )

          actor.continue()
        }
      }
    }

    PathComputedSuccess(receiver_subject, packages) -> {
      actor.continue(state)
    }

    RequestMemoized(receiver_subject, geoids) -> {
      actor.continue(state)
    }

    ReceiverRestart(receiver_subject, receiver_pool_subject) -> {
      actor.continue(state)
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
      acc |> dict.insert(process.named_subject(receiver_name), #(Idle, 0, []))
    })
  let package_queue = []
  let memoized_shortest_distances_paths = dict.new()
  let state = #(
    package_queue,
    receivers_tracker,
    memoized_shortest_distances_paths,
  )

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub opaque type ReceiverMessage {
  CalculateShortestPath(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    packages: List(Package),
  )

  ReceiveMemoizedShortestPathAndDistance(
    receiver_subject: ReceiverSubject,
    shortest_path_and_distance: #(ShortestPath, Distance),
  )
}

// T(n) = O(n!)
// S(n) = O(n * n!)
pub fn generate_geoids_permutations(list: List(Int)) -> List(List(Int)) {
  case list {
    [] -> [[]]

    list ->
      list.flat_map(list, fn(element) {
        // get the rest of the list 
        let rest =
          list
          |> list.filter(keeping: fn(elem) { elem != element })

        // recursively find all permutations of the remaining elements
        let sub_permutations = generate_geoids_permutations(rest)

        // prepend the current element to each sub-permutation to build the full permutations
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

fn create_geoid_pairs_helper(
  geoid_pairs: List(#(Int, Int)),
  path: List(Int),
  stack: List(Int),
) {
  case path, stack {
    [], [] | [], _stack -> geoid_pairs

    // starting, stack is empty
    [geoid, ..rest_geoids], [] ->
      // add geoid to stack and continue
      create_geoid_pairs_helper(geoid_pairs, rest_geoids, [geoid, ..stack])

    [curr_geoid, ..rest_geoids], [prev_geoid, ..rest_stack] ->
      // take the prev_geoid and current as pair
      // add current to stack and continue
      create_geoid_pairs_helper(
        [#(prev_geoid, curr_geoid), ..geoid_pairs],
        rest_geoids,
        [curr_geoid, ..rest_stack],
      )
  }
}

fn create_geoid_pairs(paths: List(List(GeoId))) -> List(List(#(GeoId, GeoId))) {
  // paths
  // |> list.fold(from: [], with: fn(acc, path) {
  //   let geoid_pairs = create_geoid_pairs_helper([], path, [])
  //   [geoid_pairs, ..acc]
  // })

  paths
  |> list.map(with: fn(path) { create_geoid_pairs_helper([], path, []) })
}

fn compute_distances_per_path(
  geoid_pairs_list: List(List(#(GeoId, GeoId))),
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
) -> List(#(List(#(GeoId, GeoId)), Distance)) {
  geoid_pairs_list
  |> list.map(with: fn(geoid_pairs) {
    // compute distance for a path (permutation of geoids)
    // ex: [ [a, b], [b, c], [c, d] ]
    let path_distance =
      geoid_pairs
      |> list.fold(from: 0.0, with: fn(acc, geoid_pair) {
        let #(from, to) = geoid_pair
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

    // #([ [a, b], [b, c], [c, d] ], distance)
    #(geoid_pairs, path_distance)
  })
}

fn find_shortest_distance_path(
  path_distance_tuples: List(#(List(#(GeoId, GeoId)), Distance)),
) -> #(List(#(GeoId, GeoId)), Distance) {
  path_distance_tuples
  |> list.sort(by: fn(path_distance_tuple1, path_distance_tuple2) {
    let #(_path1, distance1) = path_distance_tuple1
    let #(_path2, distance2) = path_distance_tuple2
    float.compare(distance1, distance2)
  })
  |> list.index_fold(
    from: #([], 0.0),
    with: fn(acc, path_distance_tuple, index) {
      case index == 0 {
        True -> path_distance_tuple
        False -> acc
      }
    },
  )
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

      // sort ascending the packages as memo table keeps sorted keys
      let sorted_geoids =
        geoids
        |> list.sort(by: fn(geoid1, geoid2) { int.compare(geoid1, geoid2) })

      // check the memo table for memoized shortest path with distance
      // let memoized_path_distance_tuple=

      let shortest_distance_path =
        generate_geoids_permutations(geoids)
        |> create_geoid_pairs
        |> compute_distances_per_path(
          coordinates_store_subject,
          coordinates_cache_subject,
          navigator_subject,
        )
        |> find_shortest_distance_path

      actor.continue(state)
    }

    ReceiveMemoizedShortestPathAndDistance(
      receiver_subject,
      shortest_path_and_distance,
    ) -> {
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

fn send_to_receiver(
  receiver_subject: ReceiverSubject,
  receiver_pool_subject: ReceiverPoolSubject,
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  packages: List(Package),
) -> Nil {
  process.sleep(100)

  // io.println(
  //   "Deliverator: "
  //   <> string.inspect(receiver_subject)
  //   <> " received these packages: ",
  // )
  // packages
  // |> list.each(fn(package) {
  //   let #(package_id, content) = package
  //   io.println("\t" <> "id: " <> package_id <> "\t" <> "content: " <> content)
  // })

  actor.send(
    receiver_subject,
    CalculateShortestPath(
      receiver_subject,
      receiver_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      packages,
    ),
  )
}
