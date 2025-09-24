import constants
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import warehouse/utils

type DeliveratorPoolSubject =
  process.Subject(DeliveratorPoolMessage)

type DeliveratorSubject =
  process.Subject(DeliveratorMessage)

type DeliveratorsTracker =
  dict.Dict(
    DeliveratorSubject,
    #(List(Packet), Distance, option.Option(process.Monitor)),
  )

pub type Parcel =
  #(String, String)

pub type GeoId =
  Int

pub type Packet =
  #(GeoId, Parcel, Distance)

pub type BatchPackets =
  List(Packet)

pub type BatchesQueue =
  List(BatchPackets)

//  distance per pair-stop
pub type Distance =
  Float

// total distance covered by all deliverators
type DeliveratorPoolState =
  #(BatchesQueue, DeliveratorsTracker, Distance, DeliveratorPoolSubject)

pub opaque type DeliveratorPoolMessage {
  ReceivePackets(
    deliverator_pool_subject: DeliveratorPoolSubject,
    batch_packets: BatchPackets,
  )

  PacketDelivered(
    deliverator_subject: DeliveratorSubject,
    delivered_packet: Packet,
  )

  DeliveratorSuccess(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
  )

  Mon(process.Down)
}

fn remove_delivered_packet(
  deliverators_tracker: DeliveratorsTracker,
  deliverator_subject: DeliveratorSubject,
  delivered_packet: Packet,
) -> DeliveratorsTracker {
  deliverators_tracker
  |> dict.upsert(update: deliverator_subject, with: fn(tracking_info_maybe) {
    case tracking_info_maybe {
      option.None -> #([], 0.0, option.None)

      option.Some(tracking_info) -> {
        let #(packets, distance_so_far, monitor_ref) = tracking_info
        let #(_geoid, _packet, distance_this_delivery) = delivered_packet
        let filtered =
          packets
          |> list.filter(keeping: fn(packet_in_tracker) {
            packet_in_tracker != delivered_packet
          })

        #(filtered, distance_so_far +. distance_this_delivery, monitor_ref)
      }
    }
  })
}

fn create_and_monitor_deliverator(
  available_slots: Int,
  deliverator_pool_subject: DeliveratorPoolSubject,
  deliverators_tracker: DeliveratorsTracker,
  packets_remaining: List(Packet),
) -> #(
  process.Selector(DeliveratorPoolMessage),
  List(process.Subject(DeliveratorMessage)),
  dict.Dict(
    process.Subject(DeliveratorMessage),
    #(List(Packet), Distance, option.Option(process.Monitor)),
  ),
) {
  let available_range = list.range(from: 1, to: available_slots)

  let #(selector, new_deliverators_subjects, updated_deliverators_tracker) =
    available_range
    |> list.fold(
      from: #(
        // add selector back for deliverator pool subject
        // because actor.with_selector() replaces previously given selectors
        process.new_selector() |> process.select(deliverator_pool_subject),
        [],
        deliverators_tracker,
      ),
      with: fn(acc, _packet) {
        let #(selector, new_deliverators_subjects, updated_deliverators_tracker) =
          acc
        // creating an actor automatically links it to the calling process
        let assert Ok(new_deliverator) = new_deliverator()
        // unlinking avoids a cascading crash of the pool
        process.unlink(new_deliverator.pid)
        let monitor = process.monitor(new_deliverator.pid)
        let new_deliverator_subject = new_deliverator.data
        echo "Started new deliverator: "
          <> string.inspect(new_deliverator_subject)

        #(
          selector |> process.select_specific_monitor(monitor, Mon),
          [new_deliverator_subject, ..new_deliverators_subjects],
          updated_deliverators_tracker
            |> dict.insert(new_deliverator_subject, #(
              packets_remaining,
              0.0,
              option.Some(monitor),
            )),
        )
      },
    )

  #(selector, new_deliverators_subjects, updated_deliverators_tracker)
}

fn zip_send_to_deliverators(
  new_deliverators_subjects,
  batches,
  deliverator_pool_subject,
  deliverators_tracker,
) {
  new_deliverators_subjects
  |> list.zip(with: batches)
  |> list.fold(from: deliverators_tracker, with: fn(acc, zipped) {
    let #(deliverator_subject, batch) = zipped

    send_to_deliverator(deliverator_subject, deliverator_pool_subject, batch)

    acc
    |> dict.upsert(update: deliverator_subject, with: fn(tracking_info_maybe) {
      case tracking_info_maybe {
        option.None -> #(batch, 0.0, option.None)

        option.Some(tracking_info) -> {
          let #(_packets, distance_so_far, monitor_ref) = tracking_info
          // add batch for packet loss prevention
          #(batch, distance_so_far, monitor_ref)
        }
      }
    })
  })
}

fn batch_and_slice_queue(updated_queue: BatchesQueue, available_slots: Int) {
  updated_queue
  |> list.index_fold(from: #([], []), with: fn(acc, batch, index) {
    let #(batches, sliced_queue) = acc
    case index < available_slots {
      True -> #([batch, ..batches], sliced_queue)
      False -> #(batches, [batch, ..sliced_queue])
    }
  })
}

fn count_remaining_packets(
  updated_deliverators_tracker: DeliveratorsTracker,
) -> Int {
  updated_deliverators_tracker
  |> dict.fold(from: 0, with: fn(acc, _deliverator_subject, tracking_info) {
    let #(packets, _distance_so_far, _monitor_ref) = tracking_info
    acc + list.length(packets)
  })
}

fn find_crashed_subject_info(
  deliverators_tracker: DeliveratorsTracker,
  monitor: process.Monitor,
) {
  deliverators_tracker
  |> dict.filter(keeping: fn(_subject, tracking_info) {
    let #(_packets, _distance_so_far, monitor_ref_maybe) = tracking_info
    case monitor_ref_maybe {
      option.None -> False
      option.Some(monitor_ref) -> monitor_ref == monitor
    }
  })
  |> dict.to_list
  |> list.first
  |> result.unwrap(#(process.new_subject(), #([], 0.0, option.None)))
}

fn add_batch_to_tracking_info(
  deliverators_tracker: DeliveratorsTracker,
  deliverator_subject: DeliveratorSubject,
  batch: BatchPackets,
) -> DeliveratorsTracker {
  deliverators_tracker
  |> dict.upsert(update: deliverator_subject, with: fn(tracking_info_maybe) {
    case tracking_info_maybe {
      option.None -> #(batch, 0.0, option.None)

      option.Some(tracking_info) -> {
        let #(_packets, distance_so_far, monitor_ref) = tracking_info
        // add batch for packet loss prevention
        #(batch, distance_so_far, monitor_ref)
      }
    }
  })
}

fn handle_pool_message(
  state: DeliveratorPoolState,
  message: DeliveratorPoolMessage,
) {
  let #(
    batches_queue,
    deliverators_tracker,
    total_distance,
    // so the pool can continue to select on own subject after adding monitor
    dps_for_process_down,
  ) = state

  case message {
    ReceivePackets(deliverator_pool_subject, batch_packets) -> {
      echo "Deliverator pool received batch packets: "
        <> string.inspect(batch_packets)

      // all delivery packets "pulled" from queue
      let updated_queue = batches_queue |> list.append([batch_packets])

      let available_slots =
        constants.deliverator_pool_limit - dict.size(deliverators_tracker)

      case available_slots == 0 {
        // if all deliverators are busy, just update the queue
        True ->
          actor.continue(#(
            updated_queue,
            deliverators_tracker,
            total_distance,
            dps_for_process_down,
          ))

        // there are available deliverators, create and assign batches
        False -> {
          let #(
            selector,
            new_deliverators_subjects,
            updated_deliverators_tracker,
          ) =
            create_and_monitor_deliverator(
              available_slots,
              deliverator_pool_subject,
              deliverators_tracker,
              [],
            )

          let #(batches, sliced_queue) =
            batch_and_slice_queue(updated_queue, available_slots)

          echo "Dispatching "
            <> int.to_string(list.length(batches))
            <> " batches to deliverators"

          let updated_deliverators_tracker =
            zip_send_to_deliverators(
              new_deliverators_subjects,
              batches,
              deliverator_pool_subject,
              updated_deliverators_tracker,
            )

          actor.continue(#(
            sliced_queue,
            updated_deliverators_tracker,
            total_distance,
            dps_for_process_down,
          ))
          |> actor.with_selector(selector)
        }
      }
    }

    PacketDelivered(deliverator_subject, delivered_packet) -> {
      echo "Packet delivered by deliverator: "
        <> string.inspect(deliverator_subject)
        <> "Packet details: "
        <> string.inspect(delivered_packet)

      let updated_deliverators_tracker =
        remove_delivered_packet(
          deliverators_tracker,
          deliverator_subject,
          delivered_packet,
        )

      let packets_count = count_remaining_packets(updated_deliverators_tracker)

      io.println("_-_ " <> int.to_string(packets_count) <> " packets remaining")

      actor.continue(#(
        batches_queue,
        updated_deliverators_tracker,
        total_distance,
        dps_for_process_down,
      ))
    }

    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject) -> {
      echo "A deliverator has successfully completed its deliveries: "
        <> string.inspect(deliverator_subject)

      // check if there are more batches of packets to deliver
      case batches_queue {
        // all batches currently assigned to deliverators
        [] -> {
          // nothing more to do, stop the deliverator
          stop_deliverator(deliverator_subject)

          let deliverator_tracking_info =
            deliverators_tracker
            |> dict.get(deliverator_subject)
            |> result.unwrap(#([], 0.0, option.None))
          let #(_packets, distance_so_far, _monitor_ref) =
            deliverator_tracking_info

          actor.continue(#(
            [],
            deliverators_tracker |> dict.delete(deliverator_subject),
            // add distance covered by this deliverator to total distance
            total_distance +. distance_so_far,
            dps_for_process_down,
          ))
        }

        // there are more batches to assign to deliverators
        batches_queue -> {
          let #(batches, sliced_queue) = batch_and_slice_queue(batches_queue, 1)
          let batch = utils.get_first_batch(batches)

          let updated_deliverators_tracker =
            add_batch_to_tracking_info(
              deliverators_tracker,
              deliverator_subject,
              batch,
            )

          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            batch,
          )

          actor.continue(#(
            sliced_queue,
            updated_deliverators_tracker,
            total_distance,
            dps_for_process_down,
          ))
        }
      }
    }

    Mon(down_msg) -> {
      echo "A deliverator has crashed or exited: "

      case down_msg {
        // unlikely to happen as there are no ports used
        process.PortDown(monitor, pid, reason) -> {
          echo "PortDown reason: "
            <> string.inspect(reason)
            <> string.inspect(pid)
            <> string.inspect(monitor)

          actor.continue(state)
        }

        process.ProcessDown(monitor, pid, reason) -> {
          process.demonitor_process(monitor)
          echo "ProcessDown reason: "
            <> string.inspect(reason)
            <> string.inspect(pid)
            <> string.inspect(monitor)

          case reason {
            // stopped deliverator sends Normal reason
            process.Normal | process.Killed -> actor.continue(state)

            // deliverator has crashed and sends Abnormal reason
            process.Abnormal(rsn) -> {
              echo "Abnormal crash detected, restarting deliverator"
                <> string.inspect(rsn)

              let #(crashed_subject, tracking_info) =
                find_crashed_subject_info(deliverators_tracker, monitor)
              let #(packets_remaining, _distance_so_far, _monitor_ref_maybe) =
                tracking_info

              let #(selector, new_deliverators, updated_deliverators_tracker) =
                create_and_monitor_deliverator(
                  1,
                  dps_for_process_down,
                  deliverators_tracker |> dict.delete(crashed_subject),
                  packets_remaining,
                )

              let updated_deliverators_tracker =
                zip_send_to_deliverators(
                  new_deliverators,
                  [packets_remaining],
                  dps_for_process_down,
                  updated_deliverators_tracker,
                )

              actor.continue(#(
                batches_queue,
                updated_deliverators_tracker,
                total_distance,
                dps_for_process_down,
              ))
              |> actor.with_selector(selector)
            }
          }
        }
      }
    }
  }
}

pub fn new_pool(name: process.Name(DeliveratorPoolMessage)) {
  let batches_queue = []
  let deliverators_tracker = dict.new()
  let total_distance = 0.0
  // required for pool to select on future messages in Mon(process.Down) case
  let dps_for_process_down = process.named_subject(name)
  let state = #(
    batches_queue,
    deliverators_tracker,
    total_distance,
    dps_for_process_down,
  )

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub fn receive_packets(
  deliverator_pool_subject: DeliveratorPoolSubject,
  batch_packets: BatchPackets,
) {
  process.sleep(1000)
  actor.send(
    deliverator_pool_subject,
    ReceivePackets(deliverator_pool_subject, batch_packets),
  )
}

fn packet_delivered(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  delivered_packet: Packet,
) {
  actor.send(
    deliverator_pool_subject,
    PacketDelivered(deliverator_subject, delivered_packet),
  )
}

fn deliverator_success(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject),
  )
}

// Deliverator
pub opaque type DeliveratorMessage {
  DeliverPackets(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
    packets: List(Packet),
  )

  Stop
}

fn make_delivery() -> Nil {
  let rand_timer = int.random(3000)
  process.sleep(rand_timer)
  utils.maybe_crash()
}

fn deliver(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  packets: List(Packet),
) -> Nil {
  case packets {
    [] -> Nil
    [packet, ..rest] -> {
      make_delivery()
      packet_delivered(deliverator_subject, deliverator_pool_subject, packet)

      deliver(deliverator_subject, deliverator_pool_subject, rest)
    }
  }
}

fn handle_deliverator_message(
  state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackets(deliverator_subject, deliverator_pool_subject, packets) -> {
      deliver(deliverator_subject, deliverator_pool_subject, packets)
      deliverator_success(deliverator_subject, deliverator_pool_subject)

      actor.continue(state)
    }

    Stop -> actor.stop()
  }
}

pub fn new_deliverator() -> Result(
  actor.Started(DeliveratorSubject),
  actor.StartError,
) {
  actor.new([])
  |> actor.on_message(handle_deliverator_message)
  |> actor.start
}

fn send_to_deliverator(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  packets: List(Packet),
) -> Nil {
  process.sleep(100)

  echo "Sending batch of "
    <> int.to_string(list.length(packets))
    <> " packets to deliverator"

  actor.send(
    deliverator_subject,
    DeliverPackets(deliverator_subject, deliverator_pool_subject, packets),
  )
}

fn stop_deliverator(deliverator_subject: DeliveratorSubject) -> Nil {
  actor.send(deliverator_subject, Stop)
}
