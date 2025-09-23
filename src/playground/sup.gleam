import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import playground/deliverator

// --deliverators--

type DeliveratorPoolName =
  process.Name(deliverator.DeliveratorPoolMessage)

fn start_deliverator_pool(deliverator_pool_name: DeliveratorPoolName) {
  fn() { deliverator.new_pool(deliverator_pool_name) }
}

fn start_supervisor(
  deliverator_pool_name: DeliveratorPoolName,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(
    supervision.worker(start_deliverator_pool(deliverator_pool_name)),
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}

pub fn start_overmind() {
  let deliverator_pool_name = process.new_name(constants.deliverator_pool)
  let playground_sup_spec = start_supervisor(deliverator_pool_name)
  let assert Ok(_overmind) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(playground_sup_spec)
    |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
    |> static_supervisor.start()

  process.sleep(1000)

  let test_batch1 = [
    #(1, #("parcel_1", "content_1"), 10.5),
    #(2, #("parcel_2", "content_2"), 20.0),
    #(3, #("parcel_3", "content_3"), 15.75),
  ]
  let test_batch2 = [
    #(4, #("parcel_4", "content_4"), 5.0),
    #(5, #("parcel_5", "content_5"), 12.25),
  ]
  let test_batch3 = [
    #(6, #("parcel_6", "content_6"), 8.0),
    #(7, #("parcel_7", "content_7"), 14.5),
    #(8, #("parcel_8", "content_8"), 9.75),
    #(9, #("parcel_9", "content_9"), 11.0),
    #(10, #("parcel_10", "content_10"), 7.5),
  ]

  deliverator.receive_packets(
    process.named_subject(deliverator_pool_name),
    test_batch3,
  )
}
