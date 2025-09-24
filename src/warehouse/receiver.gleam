import constants
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import navigator/coordinates_store
import navigator/distances_cache
import navigator/navigator
import warehouse/deliverator.{type Distance, type GeoId, type Parcel}
import warehouse/utils

pub type Package =
  #(GeoId, Parcel)

type PackageQueue =
  List(Package)

pub type ReceiverPoolSubject =
  process.Subject(ReceiverPoolMessage)

pub type ReceiverSubject =
  process.Subject(ReceiverMessage)

pub type DeliveratorShipment =
  List(#(GeoId, Parcel, Distance))

pub opaque type ReceiverPoolMessage {
  ReceivePackages(
    receiver_pool_subject: ReceiverPoolSubject,
    deliverator_pool_subject: process.Subject(
      deliverator.DeliveratorPoolMessage,
    ),
    coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
    distances_cache_subject: distances_cache.DistancesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    packages: List(Package),
  )

  PathComputedSuccess(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    deliverator_pool_subject: process.Subject(
      deliverator.DeliveratorPoolMessage,
    ),
    coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
    distances_cache_subject: distances_cache.DistancesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    deliverator_shipment: DeliveratorShipment,
  )

  // ReceiverSuccess(
  //   receiver_subject: ReceiverSubject,
  //   receiver_pool_subject: ReceiverPoolSubject,
  //   deliverator_pool_subject: process.Subject(
  //     deliverator.DeliveratorPoolMessage,
  //   ),
  //   coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  //   distances_cache_subject: distances_cache.DistancesCacheSubject,
  //   navigator_subject: navigator.NavigatorSubject,
  // )
  Mon(process.Down)
  // ReceiverRestart(
  //   receiver_subject: ReceiverSubject,
  //   receiver_pool_subject: ReceiverPoolSubject,
  //   deliverator_pool_subject: process.Subject(
  //     deliverator.DeliveratorPoolMessage,
  //   ),
  //   coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  //   distances_cache_subject: distances_cache.DistancesCacheSubject,
  //   navigator_subject: navigator.NavigatorSubject,
  // )
}

type ReceiversTracker =
  dict.Dict(ReceiverSubject, #(List(Package), option.Option(process.Monitor)))

type SortedAscGeoIds =
  List(GeoId)

type ShortestPathWithDistances =
  List(#(GeoId, Distance))

type MemoizedShortestPathsDistances =
  dict.Dict(SortedAscGeoIds, ShortestPathWithDistances)

type SubjectsForProcessDown =
  #(
    ReceiverPoolSubject,
    process.Subject(deliverator.DeliveratorPoolMessage),
    coordinates_store.CoordinateStoreSubject,
    distances_cache.DistancesCacheSubject,
    navigator.NavigatorSubject,
  )

type ReceiverPoolState =
  #(
    PackageQueue,
    ReceiversTracker,
    MemoizedShortestPathsDistances,
    SubjectsForProcessDown,
  )

fn create_and_monitor_receivers(
  available_slots: Int,
  receiver_pool_subject: ReceiverPoolSubject,
  receivers_tracker: ReceiversTracker,
  packages_remaining: List(Package),
) -> #(
  process.Selector(ReceiverPoolMessage),
  List(ReceiverSubject),
  ReceiversTracker,
) {
  let available_range = list.range(from: 1, to: available_slots)

  let #(selector, new_receivers_subjects, updated_receivers_tracker) =
    available_range
    |> list.fold(
      from: #(
        // add selector back for receiver pool subject
        // because actor.with_selector() replaces previously given selectors
        process.new_selector() |> process.select(receiver_pool_subject),
        [],
        receivers_tracker,
      ),
      with: fn(acc, _package) {
        let #(selector, new_receivers_subjects, updated_receivers_tracker) = acc
        // creating an actor automatically links it to the calling process
        let assert Ok(new_receiver) = new_receiver()
        // unlinking avoids a cascading crash of the pool
        process.unlink(new_receiver.pid)
        let monitor = process.monitor(new_receiver.pid)
        let new_receiver_subject = new_receiver.data
        echo "Started new receiver: " <> string.inspect(new_receiver_subject)

        #(
          selector |> process.select_specific_monitor(monitor, Mon),
          [new_receiver_subject, ..new_receivers_subjects],
          updated_receivers_tracker
            |> dict.insert(new_receiver_subject, #(
              packages_remaining,
              option.Some(monitor),
            )),
        )
      },
    )

  #(selector, new_receivers_subjects, updated_receivers_tracker)
}

fn zip_send_to_receivers(
  coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  distances_cache_subject: distances_cache.DistancesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  deliverator_pool_subject: process.Subject(deliverator.DeliveratorPoolMessage),
  new_receivers_subjects: List(ReceiverSubject),
  batches: List(List(Package)),
  receiver_pool_subject: ReceiverPoolSubject,
  receivers_tracker: ReceiversTracker,
) -> ReceiversTracker {
  new_receivers_subjects
  |> list.zip(with: batches)
  |> list.fold(from: receivers_tracker, with: fn(acc, zipped) {
    let #(receiver_subject, batch) = zipped

    calculate_shortest_path(
      receiver_subject,
      receiver_pool_subject,
      coordinates_store_subject,
      distances_cache_subject,
      navigator_subject,
      deliverator_pool_subject,
      batch,
    )

    acc
    |> dict.upsert(update: receiver_subject, with: fn(tracking_info_maybe) {
      case tracking_info_maybe {
        option.None -> #(batch, option.None)

        option.Some(tracking_info) -> {
          let #(_packages, monitor_ref) = tracking_info
          // add batch for package loss prevention
          #(batch, monitor_ref)
        }
      }
    })
  })
}

fn add_batch_to_tracking_info(
  receivers_tracker: ReceiversTracker,
  receiver_subject: ReceiverSubject,
  batch: List(Package),
) -> ReceiversTracker {
  receivers_tracker
  |> dict.upsert(update: receiver_subject, with: fn(tracking_info_maybe) {
    case tracking_info_maybe {
      option.None -> #([], option.None)

      option.Some(tracking_info) -> {
        let #(_batch, monitor_maybe) = tracking_info
        #(batch, monitor_maybe)
      }
    }
  })
}

fn find_crashed_subject_info(
  receivers_tracker: ReceiversTracker,
  monitor_ref: process.Monitor,
) -> #(
  process.Subject(ReceiverMessage),
  #(List(#(GeoId, #(String, String))), option.Option(process.Monitor)),
) {
  receivers_tracker
  |> dict.filter(keeping: fn(_subject, tracking_info) {
    let #(_packages, monitor_maybe) = tracking_info
    case monitor_maybe {
      option.None -> False
      option.Some(monitor) -> monitor == monitor_ref
    }
  })
  |> dict.to_list
  |> list.first
  |> result.unwrap(#(process.new_subject(), #([], option.None)))
}

fn split_memoized_batches(
  batches: List(List(Package)),
  memoized_shortest_distances_paths: MemoizedShortestPathsDistances,
) -> #(
  List(List(#(GeoId, #(String, String)))),
  List(#(GeoId, #(String, String), Distance)),
) {
  // check each batch's geoids to see if memoized path exists
  batches
  |> list.fold(from: #([], []), with: fn(acc, batch) {
    let #(not_computed_batches, computed_batches) = acc

    // table required for later correct parcel insertion
    let #(geoids, geoid_parcel_table) =
      batch
      |> list.fold(from: #([], dict.new()), with: fn(ids_table_acc, tuple) {
        let #(geoids, geoid_parcel_table) = ids_table_acc
        let #(geoid, parcel) = tuple

        #(
          geoids |> list.append([geoid]),
          geoid_parcel_table |> dict.insert(geoid, parcel),
        )
      })

    // sort asc the geoids to check memo table
    let sorted_asc_geoids =
      geoids
      |> list.sort(by: fn(geoid1, geoid2) { int.compare(geoid1, geoid2) })

    case memoized_shortest_distances_paths |> dict.get(sorted_asc_geoids) {
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
}

fn split_shortest_path(
  deliverator_shipment: DeliveratorShipment,
) -> #(List(GeoId), List(#(GeoId, Distance))) {
  deliverator_shipment
  // add home base at start, because its geoid is lost when creating shipment
  // and it is required for memoization key
  |> list.prepend(#(constants.receiver_start_geoid, #("", ""), 0.0))
  |> list.fold(from: #([], []), with: fn(acc, package) {
    let #(geoids, path_with_distances) = acc
    let #(geoid, _parcel, distance) = package

    #(
      [geoid, ..geoids],
      path_with_distances |> list.append([#(geoid, distance)]),
    )
  })
}

fn handle_pool_message(state: ReceiverPoolState, message: ReceiverPoolMessage) {
  let #(
    package_queue,
    receivers_tracker,
    memoized_shortest_distances_paths,
    subjects_for_process_down,
  ) = state

  case message {
    ReceivePackages(
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      distances_cache_subject,
      navigator_subject,
      packages,
    ) -> {
      echo "packages received by receiver pool"
      echo packages

      let updated_queue = package_queue |> list.append(packages)
      let available_slots =
        constants.receiver_pool_limit - dict.size(receivers_tracker)

      let #(batches, sliced_queue) =
        utils.batch_and_slice_queue(updated_queue, available_slots)

      let #(not_computed_batches, deliverator_shipment) =
        split_memoized_batches(batches, memoized_shortest_distances_paths)

      // send computed batches to deliverator pool
      case deliverator_shipment {
        [] -> Nil

        deliverator_shipment ->
          deliverator.receive_packets(
            deliverator_pool_subject,
            deliverator_shipment,
          )
      }

      case available_slots == 0 {
        // all receivers currently computin'
        True ->
          // add to queue and continue
          actor.continue(#(
            updated_queue,
            receivers_tracker,
            memoized_shortest_distances_paths,
            subjects_for_process_down,
          ))

        // else "push" batches to new receivers
        False -> {
          let #(selector, new_receivers_subjects, updated_receivers_tracker) =
            create_and_monitor_receivers(
              list.length(not_computed_batches),
              receiver_pool_subject,
              receivers_tracker,
              sliced_queue,
            )

          let updated_receivers_tracker =
            zip_send_to_receivers(
              coordinates_store_subject,
              distances_cache_subject,
              navigator_subject,
              deliverator_pool_subject,
              new_receivers_subjects,
              not_computed_batches,
              receiver_pool_subject,
              updated_receivers_tracker,
            )

          actor.continue(#(
            sliced_queue,
            updated_receivers_tracker,
            memoized_shortest_distances_paths,
            subjects_for_process_down,
          ))
          |> actor.with_selector(selector)
        }
      }
    }

    PathComputedSuccess(
      receiver_subject,
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      distances_cache_subject,
      navigator_subject,
      deliverator_shipment,
    ) -> {
      echo "receiver reported computed shortest path"
      echo receiver_subject
      echo deliverator_shipment

      // grab geoids to insert new shortest path with distances
      let #(geoids, path_with_distances) =
        split_shortest_path(deliverator_shipment)

      // memo table keys are sorted asc set 
      let sorted_asc_geoids =
        geoids
        |> list.sort(by: fn(geoid1, geoid2) { int.compare(geoid1, geoid2) })

      // example sorted asc geoid keys :
      // #([56001962700, 56001963102, 56021001100, 56045951300]
      // example values path starting always at 'start geoid'
      // and ending always at 'end geoid':
      // [#(56001962700, 0.0), #(56001963102, 5.47), #(56021001100, 62.68), #(56045951300, 305.84)]
      let updated_memo_table =
        memoized_shortest_distances_paths
        |> dict.insert(sorted_asc_geoids, path_with_distances)

      // send ordered packages to deliverator pool for delivery
      deliverator.receive_packets(
        deliverator_pool_subject,
        deliverator_shipment,
      )

      // check if any packages remain to be delivered in queue 
      case package_queue {
        // all packages sent to deliverator pool
        [] -> {
          // nothing more to do for this receiver
          stop_receiver(receiver_subject)

          actor.continue(#(
            [],
            receivers_tracker |> dict.delete(receiver_subject),
            updated_memo_table,
            subjects_for_process_down,
          ))
        }

        // packages require computin'
        package_queue -> {
          // each successful receiver "pulls" a batch from queue
          let #(batches, sliced_queue) =
            utils.batch_and_slice_queue(package_queue, 1)
          let batch = utils.get_first_batch(batches)

          // update batch for retry if receiver fails to compute
          let updated_receivers_tracker =
            add_batch_to_tracking_info(
              receivers_tracker,
              receiver_subject,
              batch,
            )

          calculate_shortest_path(
            receiver_subject,
            receiver_pool_subject,
            coordinates_store_subject,
            distances_cache_subject,
            navigator_subject,
            deliverator_pool_subject,
            batch,
          )

          actor.continue(#(
            sliced_queue,
            updated_receivers_tracker,
            updated_memo_table,
            subjects_for_process_down,
          ))
        }
      }
    }

    Mon(process_down_message) -> {
      let #(
        receiver_pool_subject,
        deliverator_pool_subject,
        coordinates_store_subject,
        distances_cache_subject,
        navigator_subject,
      ) = subjects_for_process_down

      case process_down_message {
        process.PortDown(_monitor_ref, _pid, _reason) -> actor.continue(state)

        process.ProcessDown(monitor_ref, pid, reason) -> {
          case reason {
            process.Normal | process.Killed -> actor.continue(state)

            process.Abnormal(rsn) -> {
              let #(crashed_subject, tracking_info) =
                find_crashed_subject_info(receivers_tracker, monitor_ref)
              let #(packages_remaining, _monitor_maybe) = tracking_info

              let #(selector, new_receivers_subjects, updated_receivers_tracker) =
                create_and_monitor_receivers(
                  1,
                  receiver_pool_subject,
                  receivers_tracker |> dict.delete(crashed_subject),
                  packages_remaining,
                )

              let updated_receivers_tracker =
                zip_send_to_receivers(
                  coordinates_store_subject,
                  distances_cache_subject,
                  navigator_subject,
                  deliverator_pool_subject,
                  new_receivers_subjects,
                  [packages_remaining],
                  receiver_pool_subject,
                  updated_receivers_tracker,
                )

              actor.continue(#(
                package_queue,
                updated_receivers_tracker,
                memoized_shortest_distances_paths,
                subjects_for_process_down,
              ))
              |> actor.with_selector(selector)
            }
          }
        }
      }
    }
  }
}

pub fn new_pool(
  receiver_pool_name: process.Name(ReceiverPoolMessage),
  receiver_names: List(process.Name(ReceiverMessage)),
  coordinates_store_name: process.Name(coordinates_store.StoreMessage),
  distances_cache_name: process.Name(distances_cache.CacheMessage),
  navigator_name: process.Name(navigator.NavigatorMessage),
  deliverator_pool_name: process.Name(deliverator.DeliveratorPoolMessage),
) {
  let receivers_tracker =
    receiver_names
    |> list.fold(from: dict.new(), with: fn(acc, receiver_name) {
      let batch = []
      let monitor_maybe = option.None

      acc
      |> dict.insert(process.named_subject(receiver_name), #(
        batch,
        monitor_maybe,
      ))
    })
  let package_queue = []
  let memoized_shortest_distances_paths = dict.new()

  let receiver_pool_subject = process.named_subject(receiver_pool_name)
  let coordinates_store_subject = process.named_subject(coordinates_store_name)
  let distances_cache_subject = process.named_subject(distances_cache_name)
  let navigator_subject = process.named_subject(navigator_name)
  let deliverator_pool_subject = process.named_subject(deliverator_pool_name)
  let subjects_for_process_down = #(
    receiver_pool_subject,
    deliverator_pool_subject,
    coordinates_store_subject,
    distances_cache_subject,
    navigator_subject,
  )

  let state = #(
    package_queue,
    receivers_tracker,
    memoized_shortest_distances_paths,
    subjects_for_process_down,
  )

  actor.new(state)
  |> actor.named(receiver_pool_name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub fn receive_packages(
  receiver_pool_subject: ReceiverPoolSubject,
  deliverator_pool_subject: process.Subject(deliverator.DeliveratorPoolMessage),
  coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  distances_cache_subject: distances_cache.DistancesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  packages: List(Package),
) {
  actor.send(
    receiver_pool_subject,
    ReceivePackages(
      receiver_pool_subject,
      deliverator_pool_subject,
      coordinates_store_subject,
      distances_cache_subject,
      navigator_subject,
      packages,
    ),
  )
}

fn path_computed_success(
  receiver_subject: ReceiverSubject,
  receiver_pool_subject: ReceiverPoolSubject,
  deliverator_pool_subject: process.Subject(deliverator.DeliveratorPoolMessage),
  coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  distances_cache_subject: distances_cache.DistancesCacheSubject,
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
      distances_cache_subject,
      navigator_subject,
      deliverator_shipment,
    ),
  )
}

// <><> Receiver <><>

pub opaque type ReceiverMessage {
  CalculateShortestPath(
    receiver_subject: ReceiverSubject,
    receiver_pool_subject: ReceiverPoolSubject,
    coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
    distances_cache_subject: distances_cache.DistancesCacheSubject,
    navigator_subject: navigator.NavigatorSubject,
    deliverator_pool_subject: process.Subject(
      deliverator.DeliveratorPoolMessage,
    ),
    packages: List(Package),
  )

  Stop
}

// T(n) = O(n!)
// S(n) = O(n * n!)
// where n is the constants.batch_size defined at author time
pub fn generate_geoids_permutations(geoids: List(Int)) -> List(List(Int)) {
  case geoids {
    [] -> [[]]

    geoids ->
      // each element is transformed using flat_map into a new list of results,
      // which are then flattened into a single list
      geoids
      |> list.flat_map(fn(geoid) {
        // find all other elements in the list by deleting the current one
        let rest =
          geoids
          |> list.filter(keeping: fn(elem) { elem != geoid })

        // recursively find all permutations of the remaining elements
        let sub_permutations = generate_geoids_permutations(rest)

        // prepend the current element to each sub-permutation
        list.map(sub_permutations, fn(p) { [geoid, ..p] })
      })
  }
}

fn add_home_base_to_path(paths: List(List(Int))) -> List(List(GeoId)) {
  paths
  |> list.map(with: fn(path) {
    [constants.receiver_start_geoid, ..path]
    |> list.append([constants.receiver_end_geoid])
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
        geoid_pairs |> list.append([#(prev_geoid, curr_geoid)]),
        [curr_geoid, ..rest_stack],
      )
  }
}

fn create_geoid_pairs(paths: List(List(GeoId))) -> List(List(#(GeoId, GeoId))) {
  paths
  |> list.map(with: fn(path) { path |> create_geoid_pairs_helper([], []) })
}

fn compute_distance_per_pair(
  geoid_pairs_list: List(List(#(GeoId, GeoId))),
  coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  distances_cache_subject: distances_cache.DistancesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
) -> List(List(#(#(GeoId, GeoId), Distance))) {
  geoid_pairs_list
  |> list.map(with: fn(geoid_pairs) {
    // compute distance for a path (permutation of geoids)
    // ex: [ [1, 2], [2, 3], [3, 4] ]
    // where 1 is always start geoid and 4 is always end geoid
    // and 2, 3 are the geoids with parcels to deliver
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
          distances_cache_subject,
        )

      #(geoid_pair, distance)
    })
  })
}

fn calculate_path_distance(
  geoid_pair_distance_tuples: List(#(#(GeoId, GeoId), Distance)),
) -> Distance {
  geoid_pair_distance_tuples
  |> list.fold(from: 0.0, with: fn(acc, tuple) {
    let #(_pair, distance) = tuple
    acc +. distance
  })
}

fn find_shortest_distance_path(
  geoid_pair_distance_tuples: List(List(#(#(GeoId, GeoId), Distance))),
) -> List(#(#(GeoId, GeoId), Distance)) {
  geoid_pair_distance_tuples
  |> list.sort(by: fn(tuple1, tuple2) {
    let distance1 = calculate_path_distance(tuple1)
    let distance2 = calculate_path_distance(tuple2)

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
  shortest_distance_path: List(#(#(GeoId, GeoId), Distance)),
  geoid_parcel_table: dict.Dict(GeoId, Parcel),
) -> DeliveratorShipment {
  shortest_distance_path
  |> list.index_fold(from: [], with: fn(acc, geoid_pair_distance, index) {
    let #(geoid_pair, distance) = geoid_pair_distance
    let #(from, to) = geoid_pair
    let parcel =
      geoid_parcel_table |> dict.get(to) |> result.unwrap(or: #("", ""))

    // the first shipment also includes the home_start base with empty parcel
    case index == 0 {
      True ->
        acc |> list.append([#(from, #("", ""), 0.0), #(to, parcel, distance)])
      // the last shipment is empty parcel as it's home_end
      False -> acc |> list.append([#(to, parcel, distance)])
    }
  })
  // shortest_distance_path
  // |> list.map(with: fn(geoid_pair_distance) {
  //   let #(geoid_pair, distance) = geoid_pair_distance
  //   let #(_from, to) = geoid_pair

  //   // the last shipment is empty parcel as it's home_end
  //   let parcel =
  //     geoid_parcel_table |> dict.get(to) |> result.unwrap(or: #("", ""))

  //   #(to, parcel, distance)
  // })
}

fn handle_receiver_message(state: List(Nil), message: ReceiverMessage) {
  case message {
    CalculateShortestPath(
      receiver_subject,
      receiver_pool_subject,
      coordinates_store_subject,
      distances_cache_subject,
      navigator_subject,
      deliverator_pool_subject,
      packages,
    ) -> {
      echo "Receiver received packages to compute shortest path"
      echo packages

      // since the parcels are removed from the geoids,
      // the table is required for correct re-assignment
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
        |> compute_distance_per_pair(
          coordinates_store_subject,
          distances_cache_subject,
          navigator_subject,
        )
        |> find_shortest_distance_path
        |> create_deliverator_shipment(geoid_parcel_table)

      utils.maybe_crash()

      path_computed_success(
        receiver_subject,
        receiver_pool_subject,
        deliverator_pool_subject,
        coordinates_store_subject,
        distances_cache_subject,
        navigator_subject,
        deliverator_shipment,
      )

      actor.continue(state)
    }

    Stop -> actor.stop()
  }
}

pub fn new_receiver() {
  actor.new([])
  |> actor.on_message(handle_receiver_message)
  |> actor.start
}

fn calculate_shortest_path(
  receiver_subject: ReceiverSubject,
  receiver_pool_subject: ReceiverPoolSubject,
  coordinates_store_subject: coordinates_store.CoordinateStoreSubject,
  distances_cache_subject: distances_cache.DistancesCacheSubject,
  navigator_subject: navigator.NavigatorSubject,
  deliverator_pool_subject: process.Subject(deliverator.DeliveratorPoolMessage),
  packages: List(Package),
) -> Nil {
  actor.send(
    receiver_subject,
    CalculateShortestPath(
      receiver_subject,
      receiver_pool_subject,
      coordinates_store_subject,
      distances_cache_subject,
      navigator_subject,
      deliverator_pool_subject,
      packages,
    ),
  )
}

fn stop_receiver(receiver_subject: ReceiverSubject) {
  actor.send(receiver_subject, Stop)
}
