import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import warehouse/utils

type DeliveratorPoolSubject =
  process.Subject(DeliveratorPoolMessage)

type DeliveratorSubject =
  process.Subject(DeliveratorMessage)

type DeliveratorsTracker =
  dict.Dict(DeliveratorSubject, #(List(Packet), Distance))

pub type Parcel =
  #(String, String)

pub type GeoId =
  Int

pub type Packet =
  #(GeoId, Parcel, Distance)

type PacketQueue =
  List(Packet)

pub type Distance =
  Float

type DeliveratorPoolState =
  #(PacketQueue, DeliveratorsTracker)

pub opaque type DeliveratorPoolMessage {
  ReceivePackets(
    deliverator_pool_subject: DeliveratorPoolSubject,
    packets: List(Packet),
  )

  PacketDelivered(
    deliverator_subject: DeliveratorSubject,
    delivered_packet: Packet,
  )

  StartListeningTo(selector: process.Selector(DeliveratorPoolMessage))

  Mon(process.Down)
  // DeliveratorSuccess(
  //   deliverator_subject: DeliveratorSubject,
  //   deliverator_pool_subject: DeliveratorPoolSubject,
  // )

  // DeliveratorRestart(
  //   deliverator_subject: DeliveratorSubject,
  //   deliverator_pool_subject: DeliveratorPoolSubject,
  // )
}

fn remove_delivered_packet(
  deliverators_tracker,
  deliverator_subject,
  delivered_packet: Packet,
) -> DeliveratorsTracker {
  deliverators_tracker
  |> dict.upsert(update: deliverator_subject, with: fn(tracking_info_maybe) {
    case tracking_info_maybe {
      option.None -> #([], 0.0)

      option.Some(tracking_info) -> {
        let #(packets, distance_so_far) = tracking_info
        let #(_geoid, _packet, distance_this_delivery) = delivered_packet
        let filtered =
          packets
          |> list.filter(keeping: fn(packet_in_tracker) {
            packet_in_tracker != delivered_packet
          })

        #(filtered, distance_so_far +. distance_this_delivery)
      }
    }
  })
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

      // let queue_length = list.length(updated_queue)
      let max_pool_limit = 20
      let deliverator_count = dict.size(deliverators_tracker)
      let available_slots = max_pool_limit - deliverator_count
      let available_range = list.range(from: 0, to: available_slots)

      let #(monitors, new_deliverators) =
        available_range
        |> list.fold(from: #([], []), with: fn(acc, _packet) {
          let #(monitors, new_deliverators) = acc
          let assert Ok(new_deliverator) = new_deliverator()
          let new_deliverator_subject = new_deliverator.data

          let monitor = process.monitor(new_deliverator.pid)
          #([monitor, ..monitors], [new_deliverator_subject, ..new_deliverators])
        })

      let selector =
        monitors
        |> list.fold(from: process.new_selector(), with: fn(acc, monitor_ref) {
          acc |> process.select_specific_monitor(monitor_ref, Mon)
        })

      let #(batches, sliced_queue) =
        utils.batch_and_slice_queue(updated_queue, available_slots)
      echo "Dispatching "
      echo int.to_string(list.length(batches))
      echo " batches to deliverators"

      let updated_deliverators_tracker =
        new_deliverators
        |> list.zip(with: batches)
        |> list.fold(from: deliverators_tracker, with: fn(acc, zipped) {
          let #(deliverator_subject, batch) = zipped

          send_to_deliverator(
            deliverator_subject,
            deliverator_pool_subject,
            batch,
          )

          acc |> dict.insert(deliverator_subject, #(batch, 0.0))
        })

      actor.continue(#(sliced_queue, updated_deliverators_tracker))
      |> actor.with_selector(selector)
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
            let #(packets, _distance_so_far) = tracking_info
            acc + list.length(packets)
          },
        )

      io.println(
        "_-_ " <> int.to_string(packets_remaining_count) <> " packets remaining",
      )

      actor.continue(#(packet_queue, updated_deliverators_tracker))
    }

    StartListeningTo(selector) -> {
      actor.continue(state) |> actor.with_selector(selector)
    }

    Mon(down_msg) -> {
      echo "A deliverator has crashed or exited: "
      echo string.inspect(down_msg)

      actor.continue(state)
    }
  }
}

pub fn new_pool(name: process.Name(DeliveratorPoolMessage)) {
  let deliverators_tracker = dict.new()
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

// Deliverator
pub opaque type DeliveratorMessage {
  DeliverPackets(
    deliverator_subject: DeliveratorSubject,
    deliverator_pool_subject: DeliveratorPoolSubject,
    packets: List(Packet),
  )
}

fn make_delivery() -> Nil {
  let rand_timer = int.random(1000)
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
  _state: List(Nil),
  message: DeliveratorMessage,
) -> actor.Next(List(Nil), a) {
  case message {
    DeliverPackets(deliverator_subject, deliverator_pool_subject, packets) -> {
      deliver(deliverator_subject, deliverator_pool_subject, packets)
      // deliverator_success(deliverator_subject, deliverator_pool_subject)

      // actor.continue(state)
      actor.stop()
    }
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
