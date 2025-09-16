import constants
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/otp/supervision
import warehouse/team

fn start_deliverator_pool(
  deliverator_pool_name: process.Name(team.DeliveratorPoolMessage),
  deliverator_names: List(process.Name(team.DeliveratorMessage)),
) {
  fn() { team.new_pool(deliverator_pool_name, deliverator_names) }
}

fn start_deliverator(
  deliverator_name: process.Name(team.DeliveratorMessage),
  deliverator_pool_name: process.Name(team.DeliveratorPoolMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    team.deliverator_restart(deliverator_subject, deliverator_pool_subject)
    team.new_deliverator(deliverator_name)
  }
}

fn generate_deliverator_name(
  max_pool_limit,
) -> process.Name(team.DeliveratorMessage) {
  let names_pool = [
    "Hiro Protagonist", "Yours Truly", "Lagoon", "Ng", "Vitaly Chernobyl",
  ]
  let length = list.length(names_pool)
  let random_index = int.random(length)
  let random_name =
    names_pool
    |> list.index_fold(from: "", with: fn(acc, name, index) {
      case index == random_index {
        True -> name <> int.to_string(max_pool_limit)
        False -> acc
      }
    })
  process.new_name(random_name)
}

fn generate_deliverator_names(
  names: List(process.Name(team.DeliveratorMessage)),
  max_pool_limit,
) -> List(process.Name(team.DeliveratorMessage)) {
  case max_pool_limit == 0 {
    True -> names
    False ->
      generate_deliverator_names(
        [generate_deliverator_name(max_pool_limit), ..names],
        max_pool_limit - 1,
      )
  }
}

fn start_deliverators(
  pool_sup_builder: static_supervisor.Builder,
  deliverator_pool_name: process.Name(team.DeliveratorPoolMessage),
  deliverator_names: List(process.Name(team.DeliveratorMessage)),
) -> static_supervisor.Builder {
  deliverator_names
  |> list.fold(from: pool_sup_builder, with: fn(acc, deliverator_name) {
    acc
    |> static_supervisor.add(
      supervision.worker(start_deliverator(
        deliverator_name,
        deliverator_pool_name,
      )),
    )
  })
}

pub fn start_supervisor(
  deliverator_pool_name: process.Name(team.DeliveratorPoolMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let deliverator_names =
    generate_deliverator_names([], constants.max_pool_limit)

  let pool_sup_builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(start_deliverator_pool(
        deliverator_pool_name,
        deliverator_names,
      )),
    )

  start_deliverators(pool_sup_builder, deliverator_pool_name, deliverator_names)
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
