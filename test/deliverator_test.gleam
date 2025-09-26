import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import warehouse/sup

pub fn deliverator_test() {
  let navigator_name = process.new_name(constants.navigator)
  let deliverator_pool_name = process.new_name(constants.deliverator_pool)
  let receiver_pool_name = process.new_name(constants.receiver_pool)

  let warehouse_sup_spec =
    sup.start_warehouse_supervisor(
      receiver_pool_name,
      deliverator_pool_name,
      navigator_name,
    )

  process.sleep(1000)

  let assert Ok(_overmind) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(warehouse_sup_spec)
    |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
    |> static_supervisor.start()
}
