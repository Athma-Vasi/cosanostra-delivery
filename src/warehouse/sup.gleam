import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import warehouse/pool

fn start_deliverator1(
  deliverator_pool_name: process.Name(pool.DeliveratorPoolMessage),
  deliverator_name: process.Name(pool.DeliveratorMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    pool.deliverator_restart(deliverator_subject, deliverator_pool_subject)
    pool.new_deliverator(deliverator_name)
  }
}

fn start_deliverator2(
  deliverator_pool_name: process.Name(pool.DeliveratorPoolMessage),
  deliverator_name: process.Name(pool.DeliveratorMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    pool.deliverator_restart(deliverator_subject, deliverator_pool_subject)
    pool.new_deliverator(deliverator_name)
  }
}

fn start_deliverator3(
  deliverator_pool_name: process.Name(pool.DeliveratorPoolMessage),
  deliverator_name: process.Name(pool.DeliveratorMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    pool.deliverator_restart(deliverator_subject, deliverator_pool_subject)
    pool.new_deliverator(deliverator_name)
  }
}

fn start_deliverator4(
  deliverator_pool_name: process.Name(pool.DeliveratorPoolMessage),
  deliverator_name: process.Name(pool.DeliveratorMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    pool.deliverator_restart(deliverator_subject, deliverator_pool_subject)
    pool.new_deliverator(deliverator_name)
  }
}

fn start_deliverator5(
  deliverator_pool_name: process.Name(pool.DeliveratorPoolMessage),
  deliverator_name: process.Name(pool.DeliveratorMessage),
) {
  fn() {
    let deliverator_subject = process.named_subject(deliverator_name)
    let deliverator_pool_subject = process.named_subject(deliverator_pool_name)

    pool.deliverator_restart(deliverator_subject, deliverator_pool_subject)
    pool.new_deliverator(deliverator_name)
  }
}

fn start_deliverator_pool(
  name: process.Name(pool.DeliveratorPoolMessage),
  deliverator_names: List(process.Name(pool.DeliveratorMessage)),
) {
  fn() { pool.new_pool(name, deliverator_names) }
}

pub fn start_supervisor(
  deliverator_name1: process.Name(pool.DeliveratorMessage),
  deliverator_name2: process.Name(pool.DeliveratorMessage),
  deliverator_name3: process.Name(pool.DeliveratorMessage),
  deliverator_name4: process.Name(pool.DeliveratorMessage),
  deliverator_name5: process.Name(pool.DeliveratorMessage),
  deliverator_pool_name: process.Name(pool.DeliveratorPoolMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let deliverator_names = [
    deliverator_name1,
    deliverator_name2,
    deliverator_name3,
    deliverator_name4,
    deliverator_name5,
  ]
  let builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(start_deliverator_pool(
        deliverator_pool_name,
        deliverator_names,
      )),
    )

  builder
  |> static_supervisor.add(
    supervision.worker(start_deliverator1(
      deliverator_pool_name,
      deliverator_name1,
    )),
  )
  |> static_supervisor.add(
    supervision.worker(start_deliverator2(
      deliverator_pool_name,
      deliverator_name2,
    )),
  )
  |> static_supervisor.add(
    supervision.worker(start_deliverator3(
      deliverator_pool_name,
      deliverator_name3,
    )),
  )
  |> static_supervisor.add(
    supervision.worker(start_deliverator4(
      deliverator_pool_name,
      deliverator_name4,
    )),
  )
  |> static_supervisor.add(
    supervision.worker(start_deliverator5(
      deliverator_pool_name,
      deliverator_name5,
    )),
  )
  |> static_supervisor.restart_tolerance(intensity: 10, period: 1000)
  |> static_supervisor.supervised()
}
