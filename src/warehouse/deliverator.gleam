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

pub opaque type DeliveratorPoolMessage {
  ReceivePackets(
    deliverator_pool_subject: DeliveratorPoolSubject,
    packets: List(Packet),
  )

  PacketDelivered(
    deliverator_subject: DeliveratorSubject,
    delivered_packet: Packet,
  )

  DeliveratorSuccess(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
  )

  DeliveratorRestart(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
  )
}

pub opaque type DeliveratorStatus {
  Busy
  Idle
}

type DeliveratorsTracker =
  dict.Dict(
    DeliveratorSubject,
    #(DeliveratorStatus, Int, List(Packet), Distance),
  )

type Parcel =
  #(String, String)

type GeoId =
  Int

type PacketQueue =
  List(Packet)

type Distance =
  Float

type Packet =
  #(GeoId, Parcel, Distance)

type DeliveratorPoolState =
  #(PacketQueue, DeliveratorsTracker)

fn remove_delivered_packet(
  deliverators_tracker,
  deliverator_subject,
  delivered_packet: Packet,
) -> DeliveratorsTracker {
  deliverators_tracker
  |> dict.upsert(update: deliverator_subject, with: fn(tracking_info_maybe) {
    case tracking_info_maybe {
      option.None -> #(Busy, 0, [], 0.0)

      option.Some(tracking_info) -> {
        let #(status, restarts, packets, distance_so_far) = tracking_info
        let #(_geoid, _packet, distance_this_delivery) = delivered_packet
        let filtered =
          packets
          |> list.filter(keeping: fn(packet_in_tracker) {
            packet_in_tracker != delivered_packet
          })

        #(status, restarts, filtered, distance_so_far +. distance_this_delivery)
      }
    }
  })
}

fn find_available_deliverators(
  deliverators_tracker,
) -> List(#(DeliveratorSubject, Int, Distance)) {
  deliverators_tracker
  |> dict.fold(from: [], with: fn(acc, deliverator_subject, tracking_info) {
    let #(status, restarts, packets, distance_so_far) = tracking_info
    case status, packets {
      Idle, [] -> [#(deliverator_subject, restarts, distance_so_far), ..acc]

      Idle, _packets | Busy, [] | Busy, _packets -> acc
    }
  })
}

fn send_batches_to_available_deliverators(
  updated_deliverators_tracker: DeliveratorsTracker,
  available_deliverators: List(#(DeliveratorSubject, Int, Distance)),
  batches: List(List(Packet)),
  deliverator_pool_subject: DeliveratorPoolSubject,
) {
  case available_deliverators, batches {
    [], [] | [], _batches | _available, [] -> updated_deliverators_tracker

    [available, ..rest_availables], [batch, ..rest_batches] -> {
      let #(deliverator_subject, restarts, distance_so_far) = available
      send_to_deliverator(deliverator_subject, deliverator_pool_subject, batch)

      send_batches_to_available_deliverators(
        updated_deliverators_tracker
          |> dict.insert(deliverator_subject, #(
            Busy,
            restarts,
            batch,
            distance_so_far,
          )),
        rest_availables,
        rest_batches,
        deliverator_pool_subject,
      )
    }
  }
}

fn handle_pool_message(
  state: DeliveratorPoolState,
  message: DeliveratorPoolMessage,
) {
  let #(packet_queue, deliverators_tracker) = state

  case message {
    ReceivePackets(deliverator_pool_subject, packets) -> {
      echo "Deliverator pool received packets"

      // insert packets into queue
      let updated_queue =
        packets
        |> list.fold(from: packet_queue, with: fn(acc, packet) {
          acc |> list.append([packet])
        })

      echo "updated queue length: "
      echo updated_queue |> list.length |> int.to_string

      let available_deliverators =
        find_available_deliverators(deliverators_tracker)

      echo "available deliverators: "
      echo available_deliverators |> list.length |> int.to_string

      case available_deliverators {
        // if all busy, add to queue and continue
        [] -> actor.continue(#(updated_queue, deliverators_tracker))

        // else "push" available deliverators a batch of packets
        availables -> {
          let #(batches, sliced_queue) =
            utils.batch_and_slice_queue(updated_queue, list.length(availables))

          actor.continue(#(
            sliced_queue,
            send_batches_to_available_deliverators(
              deliverators_tracker,
              available_deliverators,
              batches,
              deliverator_pool_subject,
            ),
          ))
        }
      }
    }

    PacketDelivered(deliverator_subject, delivered_packet) -> {
      echo "Packet delivered by deliverator: "
      echo string.inspect(deliverator_subject)
      echo "Packet details: "
      echo delivered_packet

      let updated_deliverators_tracker =
        remove_delivered_packet(
          deliverators_tracker,
          deliverator_subject,
          delivered_packet,
        )

      let packets_remaining_count =
        updated_deliverators_tracker
        |> dict.fold(
          from: 0,
          with: fn(acc, _deliverator_subject, tracking_info) {
            let #(_status, _restarts, packets, _distance_so_far) = tracking_info
            acc + list.length(packets)
          },
        )

      io.println(
        "_-_ " <> int.to_string(packets_remaining_count) <> " packets remaining",
      )

      actor.continue(#(packet_queue, updated_deliverators_tracker))
    }

    // all assigned packets (batch) to this deliverator have been delivered
    DeliveratorSuccess(deliverator_subject, deliverator_pool_subject) -> {
      let #(_status, restarts, _packets, distance_so_far) =
        deliverators_tracker
        |> dict.get(deliverator_subject)
        |> result.unwrap(or: #(Idle, 0, [], 0.0))

      // check if any packets remain in queue
      case packet_queue {
        // all packets currently assigned to deliverators
        [] ->
          // update tracker and continue
          actor.continue(#(
            [],
            deliverators_tracker
              |> dict.insert(deliverator_subject, #(
                Idle,
                restarts,
                [],
                distance_so_far,
              )),
          ))

        // packets remain in queue
        packets_to_deliver -> {
          // each successful deliverator "pulls" a batch from the queue
          let #(batches, sliced_queue) =
            utils.batch_and_slice_queue(packets_to_deliver, 1)
          let batch = utils.get_first_batch(batches)
          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            batch,
          )
          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.insert(deliverator_subject, #(
              Busy,
              restarts,
              batch,
              distance_so_far,
            ))

          actor.continue(#(sliced_queue, updated_deliverators_tracker))
        }
      }
    }

    DeliveratorRestart(deliverator_subject, deliverator_pool_subject) -> {
      let #(_status, restarts, undelivered_packets, distance_so_far) =
        deliverators_tracker
        |> dict.get(deliverator_subject)
        |> result.unwrap(or: #(Idle, 0, [], 0.0))

      case restarts == 0, undelivered_packets {
        // first incarnation of deliverator
        True, [] | True, _undelivered ->
          // update tracker and continue
          actor.continue(#(
            packet_queue,
            deliverators_tracker
              |> dict.insert(deliverator_subject, #(
                Idle,
                restarts + 1,
                [],
                distance_so_far,
              )),
          ))

        // reincarnated with all assigned packets delivered
        False, [] -> {
          // check if any packets remain in queue
          case packet_queue {
            // queue is empty, all packets delivered
            [] ->
              actor.continue(#(
                [],
                deliverators_tracker
                  |> dict.insert(deliverator_subject, #(
                    Idle,
                    restarts + 1,
                    [],
                    distance_so_far,
                  )),
              ))

            // packets in queue need to be delivered
            packets_in_queue -> {
              // each reincarnated deliverator "pulls" a batch from the queue
              let #(batches, sliced_queue) =
                utils.batch_and_slice_queue(packets_in_queue, 1)
              let batch = utils.get_first_batch(batches)
              send_to_deliverator(
                deliverator_subject,
                deliverator_pool_subject,
                batch,
              )
              let updated_deliverators_tracker =
                deliverators_tracker
                |> dict.insert(deliverator_subject, #(
                  Busy,
                  restarts + 1,
                  batch,
                  distance_so_far,
                ))

              actor.continue(#(sliced_queue, updated_deliverators_tracker))
            }
          }
        }

        // reincarnated with assigned packets undelivered 
        False, undelivered -> {
          let updated_deliverators_tracker =
            deliverators_tracker
            |> dict.insert(deliverator_subject, #(
              Busy,
              restarts + 1,
              undelivered,
              distance_so_far,
            ))

          // send remaining packets to deliverator to try again
          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            undelivered,
          )

          actor.continue(#(packet_queue, updated_deliverators_tracker))
        }
      }
    }
  }
}

pub fn new_pool(
  name: process.Name(DeliveratorPoolMessage),
  deliverator_names: List(process.Name(DeliveratorMessage)),
) {
  let deliverators_tracker =
    deliverator_names
    |> list.fold(from: dict.new(), with: fn(acc, deliverator_name) {
      let status = Idle
      let restarts = 0
      let packets = []
      let distance = 0.0

      acc
      |> dict.insert(process.named_subject(deliverator_name), #(
        status,
        restarts,
        packets,
        distance,
      ))
    })
  let packet_queue = []
  let state = #(packet_queue, deliverators_tracker)

  actor.new(state)
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub fn receive_packets(
  deliverator_pool_subject: DeliveratorPoolSubject,
  packets: List(Packet),
) {
  process.sleep(1000)
  actor.send(
    deliverator_pool_subject,
    ReceivePackets(deliverator_pool_subject, packets),
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

pub fn deliverator_restart(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
) {
  actor.send(
    deliverator_pool_subject,
    DeliveratorRestart(deliverator_subject, deliverator_pool_subject),
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
}

fn maybe_crash() -> Nil {
  let crash_factor = int.random(100)
  io.println("Crash factor: " <> int.to_string(crash_factor))
  case crash_factor > constants.crash_factor_limit {
    True -> {
      io.println("Uncle Enzo is not pleased... delivery deadline missed!")
      panic as "Panic! At The Warehouse"
    }
    False -> Nil
  }
}

fn make_delivery() -> Nil {
  let rand_timer = int.random(1000)
  process.sleep(rand_timer)
  maybe_crash()
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

      // let #(packet_id, content) = packet
      // io.println(
      //   "Deliverator: "
      //   <> string.inspect(deliverator_subject)
      //   <> " successfully delivered: "
      //   <> packet_id
      //   <> "\t"
      //   <> content,
      // )

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
  }
}

pub fn new_deliverator(
  name: process.Name(DeliveratorMessage),
) -> Result(actor.Started(DeliveratorSubject), actor.StartError) {
  actor.new([])
  |> actor.named(name)
  |> actor.on_message(handle_deliverator_message)
  |> actor.start
}

fn send_to_deliverator(
  deliverator_subject: DeliveratorSubject,
  deliverator_pool_subject: DeliveratorPoolSubject,
  packets: List(Packet),
) -> Nil {
  process.sleep(100)

  // io.println(
  //   "Deliverator: "
  //   <> string.inspect(deliverator_subject)
  //   <> " received these packets: ",
  // )
  // packets
  // |> list.each(fn(packet) {
  //   let #(packet_id, content) = packet
  //   io.println("\t" <> "id: " <> packet_id <> "\t" <> "content: " <> content)
  // })

  actor.send(
    deliverator_subject,
    DeliverPackets(deliverator_subject, deliverator_pool_subject, packets),
  )
}
