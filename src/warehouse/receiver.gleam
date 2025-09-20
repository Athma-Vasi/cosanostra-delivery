import constants
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
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

type DeliveratorShipment =
  List(#(GeoId, Parcel, Distance))

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
    receiver_pool_subject: ReceiverPoolSubject,
    deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    deliverator_shipment: DeliveratorShipment,
  )

  ReceiverRestart(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
  )
}

pub opaque type ReceiverState {
  Busy
  Idle
}

type ReceiversTracker =
  dict.Dict(ReceiverSubject, #(ReceiverState, Int, List(Package)))

type SortedAscGeoIds =
  List(GeoId)

type Distance =
  Float

type ShortestPathWithDistances =
  List(#(GeoId, Distance))

type MemoizedShortestPathsDistances =
  dict.Dict(SortedAscGeoIds, ShortestPathWithDistances)

type ReceiverPoolState =
  #(PackageQueue, ReceiversTracker, MemoizedShortestPathsDistances)

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
      let updated_queue: List(#(GeoId, Parcel)) =
        package_queue |> list.append(packages)

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

      // check each batch's geoids to see if memoized path exists
      let #(not_computed_batches, deliverator_shipment) =
        batches
        |> list.fold(from: #([], []), with: fn(acc, batch) {
          let #(not_computed_batches, computed_batches) = acc

          // table required for later correct parcel insertion
          let #(geoids, geoid_parcel_table) =
            batch
            |> list.fold(
              from: #([], dict.new()),
              with: fn(ids_table_acc, tuple) {
                let #(geoids, geoid_parcel_table) = ids_table_acc
                let #(geoid, parcel) = tuple

                #(
                  geoids |> list.append([geoid]),
                  geoid_parcel_table |> dict.insert(geoid, parcel),
                )
              },
            )

          // sort asc the geoids to check memo table
          let sorted_asc_geoids =
            geoids
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
            Ok(shortest_path_and_distance) -> {
              let deliverator_shipment =
                shortest_path_and_distance
                |> list.map(with: fn(tuple) {
                  let #(geoid, distance) = tuple
                  let parcel =
                    geoid_parcel_table
                    |> dict.get(geoid)
                    |> result.unwrap(#("", ""))

                  #(geoid, parcel, distance)
                })

              #(not_computed_batches, deliverator_shipment)
            }
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
            not_computed_batches
            |> list.zip(availables)
            |> list.fold(from: receivers_tracker, with: fn(acc, zipped) {
              let #(not_computed_batch, available) = zipped
              let #(receiver_subject, restarts) = available

              calculate_shortest_path(
                receiver_subject,
                receiver_pool_subject,
                coordinates_store_subject,
                coordinates_cache_subject,
                navigator_subject,
                deliverator_pool_subject,
                not_computed_batch,
              )

              acc
              |> dict.insert(receiver_subject, #(
                Busy,
                restarts,
                not_computed_batch,
              ))
            })

          actor.continue(#(
            sliced_queue,
            updated_receivers_tracker,
            memoized_shortest_distances_paths,
          ))
        }
      }
    }

    PathComputedSuccess(
      receiver_subject,
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      deliverator_shipment,
    ) -> {
      // grab geoids to insert new shortest path with distances
      let #(geoids, path_with_distances) =
        deliverator_shipment
        |> list.fold(from: #([], []), with: fn(acc, packet) {
          let #(geoids, path_with_distances) = acc
          let #(geoid, _parcel, distance) = packet

          #([geoid, ..geoids], [#(geoid, distance), ..path_with_distances])
        })

      // memo table keys are sorted asc set 
      let sorted_asc_geoids =
        geoids
        |> list.sort(by: fn(geoid1, geoid2) { int.compare(geoid1, geoid2) })

      let updated_memo_table =
        memoized_shortest_distances_paths
        |> dict.insert(sorted_asc_geoids, path_with_distances)

      // send ordered packages to deliverator pool for delivery
      pool.receive_packages(deliverator_pool_subject, [])

      // check if any packages remain to be delivered in queue 
      case package_queue {
        // all packages sent to deliverator pool
        [] -> {
          let updated_receivers_tracker =
            receivers_tracker
            |> dict.upsert(
              update: receiver_subject,
              with: fn(tracking_info_maybe) {
                case tracking_info_maybe {
                  option.None -> #(Idle, 0, [])

                  option.Some(tracking_info) -> {
                    let #(_status, restarts, _batch) = tracking_info
                    #(Idle, restarts, [])
                  }
                }
              },
            )

          actor.continue(#([], updated_receivers_tracker, updated_memo_table))
        }

        // packages require computin'
        package_queue -> {
          // each successfull receiver "pulls" a batch from queue
          let #(batches, sliced_queue) =
            utils.batch_and_slice_queue(package_queue, 1)
          let batch = utils.get_first_batch(batches)

          // update status and batch for retry if receiver fails to compute
          let updated_receivers_tracker =
            receivers_tracker
            |> dict.upsert(
              update: receiver_subject,
              with: fn(tracking_info_maybe) {
                case tracking_info_maybe {
                  option.None -> #(Idle, 0, [])

                  option.Some(tracking_info) -> {
                    let #(_status, restarts, _batch) = tracking_info
                    #(Busy, restarts, batch)
                  }
                }
              },
            )

          calculate_shortest_path(
            receiver_subject,
            receiver_pool_subject,
            coordinates_store_subject,
            coordinates_cache_subject,
            navigator_subject,
            deliverator_pool_subject,
            batch,
          )

          actor.continue(#(
            sliced_queue,
            updated_receivers_tracker,
            updated_memo_table,
          ))
        }
      }
    }

    ReceiverRestart(
      receiver_subject,
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
    ) -> {
      let #(_status, restarts, not_computed_batch) =
        receivers_tracker
        |> dict.get(receiver_subject)
        |> result.unwrap(or: #(Idle, 0, []))

      case restarts == 0, not_computed_batch {
        // first incarnation of receiver
        True, [] | True, _not_computed_batch ->
          // update tracker and continue

          actor.continue(#(
            package_queue,
            receivers_tracker
              |> dict.insert(receiver_subject, #(Idle, restarts + 1, [])),
            memoized_shortest_distances_paths,
          ))

        // reincarnated with assigned batch computed
        False, [] -> {
          // check if any packages in queue needs computin'
          case package_queue {
            // all batches assigned to receivers
            [] ->
              // update tracker and continue
              actor.continue(#(
                package_queue,
                receivers_tracker
                  |> dict.insert(receiver_subject, #(Idle, restarts + 1, [])),
                memoized_shortest_distances_paths,
              ))

            // packages in queue needs computin'
            package_queue -> {
              // each reincarnated receiver "pulls" a batch from queue
              let #(batches, sliced_queue) =
                utils.batch_and_slice_queue(package_queue, 1)
              let batch = utils.get_first_batch(batches)

              // update status and batch for retry if receiver fails to compute
              let updated_receivers_tracker =
                receivers_tracker
                |> dict.upsert(
                  update: receiver_subject,
                  with: fn(tracking_info_maybe) {
                    case tracking_info_maybe {
                      option.None -> #(Idle, 0, [])

                      option.Some(tracking_info) -> {
                        let #(_status, restarts, _batch) = tracking_info
                        #(Busy, restarts, batch)
                      }
                    }
                  },
                )

              calculate_shortest_path(
                receiver_subject,
                receiver_pool_subject,
                coordinates_store_subject,
                coordinates_cache_subject,
                navigator_subject,
                deliverator_pool_subject,
                batch,
              )

              actor.continue(#(
                sliced_queue,
                updated_receivers_tracker,
                memoized_shortest_distances_paths,
              ))
            }
          }
        }

        // reincarnated with assigned batch not computed
        False, not_computed_batch -> {
          let updated_receivers_tracker =
            receivers_tracker
            |> dict.insert(receiver_subject, #(
              Busy,
              restarts + 1,
              not_computed_batch,
            ))

          // send remaining batch to try again
          calculate_shortest_path(
            receiver_subject,
            receiver_pool_subject,
            coordinates_store_subject,
            coordinates_cache_subject,
            navigator_subject,
            deliverator_pool_subject,
            not_computed_batch,
          )

          actor.continue(#(
            package_queue,
            updated_receivers_tracker,
            memoized_shortest_distances_paths,
          ))
        }
      }
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

pub fn receive_packages(
  receiver_pool_subject: ReceiverPoolSubject,
  deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  packages: List(Package),
) {
  actor.send(
    receiver_pool_subject,
    ReceivePackages(
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      packages,
    ),
  )
}

fn path_computed_success(
  receiver_subject: ReceiverSubject,
  receiver_pool_subject: ReceiverPoolSubject,
  deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  deliverator_shipment: DeliveratorShipment,
) {
  actor.send(
    receiver_pool_subject,
    PathComputedSuccess(
      receiver_subject,
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      deliverator_shipment,
    ),
  )
}

pub fn receiver_restart(
  receiver_subject: ReceiverSubject,
  receiver_pool_subject: ReceiverPoolSubject,
  deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
) {
  actor.send(
    receiver_pool_subject,
    ReceiverRestart(
      receiver_subject,
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
    ),
  )
}

// <><> Receiver <><>

pub opaque type ReceiverMessage {
  CalculateShortestPath(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    coordinates_store_subject: store.CoordinateStoreSubject,
    coordinates_cache_subject: cache.CoordinatesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
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

fn add_home_base_to_path(paths: List(List(Int))) -> List(List(GeoId)) {
  paths
  |> list.map(with: fn(path) {
    [constants.receiver_home_geoid, ..path]
    |> list.append([constants.receiver_home_geoid])
  })
}

fn create_geoid_pairs_helper(
  path: List(Int),
  geoid_pairs: List(#(Int, Int)),
  stack: List(Int),
) {
  case stack, path {
    _stack, [] -> geoid_pairs

    // starting, stack is empty
    [], [geoid, ..rest_geoids] ->
      // add geoid to stack and continue
      create_geoid_pairs_helper(rest_geoids, geoid_pairs, [geoid, ..stack])

    [prev_geoid, ..rest_stack], [curr_geoid, ..rest_geoids] ->
      // take the prev_geoid and current as pair
      // add current to stack and continue
      create_geoid_pairs_helper(
        rest_geoids,
        [#(prev_geoid, curr_geoid), ..geoid_pairs],
        [curr_geoid, ..rest_stack],
      )
  }
}

fn create_geoid_pairs(paths: List(List(GeoId))) -> List(List(#(GeoId, GeoId))) {
  paths
  |> list.map(with: fn(path) { path |> create_geoid_pairs_helper([], []) })
}

fn compute_distances_per_pair(
  geoid_pairs_list: List(List(#(GeoId, GeoId))),
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
) -> List(List(#(#(GeoId, GeoId), Distance))) {
  geoid_pairs_list
  |> list.map(with: fn(geoid_pairs) {
    // compute distance for a path (permutation of geoids)
    // ex: [ [1, 2], [2, 3], [3, 4] ]
    // #([ #(#(1, 2), distance), #(#(2, 3), distance), #(#(3, 4), distance) ])    
    geoid_pairs
    |> list.map(with: fn(geoid_pair) {
      let #(from, to) = geoid_pair
      let distance =
        navigator.get_distance(
          navigator_subject,
          from,
          to,
          coordinates_store_subject,
          coordinates_cache_subject,
        )

      #(geoid_pair, distance)
    })
  })
}

fn find_shortest_distance_path(
  geoid_pair_distance_tuples: List(List(#(#(GeoId, GeoId), Distance))),
) -> List(#(#(GeoId, GeoId), Distance)) {
  geoid_pair_distance_tuples
  |> list.sort(by: fn(list1, list2) {
    let distance1 =
      list1
      |> list.fold(from: 0.0, with: fn(acc, tuple) {
        let #(_pair, distance) = tuple
        acc +. distance
      })

    let distance2 =
      list2
      |> list.fold(from: 0.0, with: fn(acc, tuple) {
        let #(_pair, distance) = tuple
        acc +. distance
      })

    float.compare(distance1, distance2)
  })
  |> list.index_fold(from: [], with: fn(acc, pair_distances, index) {
    case index == 0 {
      True -> pair_distances
      False -> acc
    }
  })
}

fn create_deliverator_shipment(
  geoid_pair_distances: List(#(#(GeoId, GeoId), Distance)),
  geoid_parcel_table: dict.Dict(GeoId, Parcel),
) -> DeliveratorShipment {
  geoid_pair_distances
  |> list.map(with: fn(geoid_pair_distance) {
    let #(geoid_pair, distance) = geoid_pair_distance
    let #(_from, to) = geoid_pair
    let parcel =
      geoid_parcel_table |> dict.get(to) |> result.unwrap(or: #("", ""))

    #(to, parcel, distance)
  })
}

fn handle_receiver_message(state: List(Nil), message: ReceiverMessage) {
  case message {
    CalculateShortestPath(
      receiver_subject,
      receiver_pool_subject,
      coordinates_store_subject,
      coordinates_cache_subject,
      navigator_subject,
      deliverator_pool_subject,
      packages,
    ) -> {
      // as the parcels are removed from the geoids,
      // the table is required for correct assignment
      let #(geoids, geoid_parcel_table) =
        packages
        |> list.fold(from: #([], dict.new()), with: fn(acc, tuple) {
          let #(geoids, geoid_parcel_table) = acc
          let #(geoid, parcel) = tuple

          #([geoid, ..geoids], geoid_parcel_table |> dict.insert(geoid, parcel))
        })

      let deliverator_shipment =
        generate_geoids_permutations(geoids)
        |> add_home_base_to_path
        |> create_geoid_pairs
        |> compute_distances_per_pair(
          coordinates_store_subject,
          coordinates_cache_subject,
          navigator_subject,
        )
        |> find_shortest_distance_path
        |> create_deliverator_shipment(geoid_parcel_table)

      path_computed_success(
        receiver_subject,
        receiver_pool_subject,
        deliverator_pool_subject,
        coordinates_store_subject,
        coordinates_cache_subject,
        navigator_subject,
        deliverator_shipment,
      )

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

fn calculate_shortest_path(
  receiver_subject: ReceiverSubject,
  receiver_pool_subject: ReceiverPoolSubject,
  coordinates_store_subject: store.CoordinateStoreSubject,
  coordinates_cache_subject: cache.CoordinatesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  deliverator_pool_subject: process.Subject(pool.DeliveratorPoolMessage),
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
      deliverator_pool_subject,
      packages,
    ),
  )
}
