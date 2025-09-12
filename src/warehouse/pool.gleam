import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/option
import gleam/otp/actor
import warehouse/subs

pub type PoolMessage {
  AvailableDeliverator
  FlagDeliveratorBusy
  FlagDeliveratorIdle
  RemoveDeliverator
}

type DeliveratorStatus {
  Busy
  Idle
}

const max_pool_limit = 10

fn handle_pool_message(
  state: dict.Dict(process.Subject(subs.DeliveratorMessage), DeliveratorStatus),
  message,
) {
  case message {
    AvailableDeliverator -> {
      todo
      // will fetch an idle or start new if current size < max
      let available =
        state
        |> dict.fold(from: option.None, with: fn(acc, deliverator, status) {
          case status {
            Busy -> acc
            Idle -> option.Some(deliverator)
          }
        })

      case available {
        option.None -> {
          let active =
            state
            |> dict.fold(from: 0, with: fn(acc, deliverator, status) {
              case status {
                Busy -> acc + 1
                Idle -> acc
              }
            })

          case active < max_pool_limit {
            
          }
        }
        option.Some(deliverator) -> {
          todo
        }
      }
    }
    FlagDeliveratorBusy -> {
      todo
      // update status of deliverator
    }
    FlagDeliveratorIdle -> {
      todo
      // update status of deliverator
    }
    RemoveDeliverator -> {
      todo
      // removes deliverator
    }
  }
}

pub fn new_pool(name: process.Name(PoolMessage)) {
  actor.new(dict.new())
  |> actor.named(name)
  |> actor.on_message(handle_pool_message)
  |> actor.start
}

pub fn available_deliverator() {
  todo
}
