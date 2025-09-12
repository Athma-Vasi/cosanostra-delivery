import gleam/erlang/process
import gleam/otp/actor

type Message {
  Ping(respond_with: process.Subject(String))
  StartListeningTo(selector: process.Selector(Message))
}

pub fn ping() {
  let assert Ok(a) =
    actor.new([""])
    |> actor.on_message(fn(state, msg: Message) {
      case msg {
        StartListeningTo(selector) -> {
          echo "listening to new selector"
          actor.continue(state)
          |> actor.with_selector(selector)
        }
        Ping(respond_with) -> {
          echo "Pong"
          process.send(respond_with, "pong")
          actor.continue(state)
        }
      }
    })
    |> actor.start

  let name = process.new_name("test_name")
  let assert Ok(_) = process.register(a.pid, name)

  let new_subject = process.named_subject(name)

  let selector = process.new_selector() |> process.select(new_subject)

  actor.send(a.data, StartListeningTo(selector))

  process.sleep(100)

  echo process.call(new_subject, 500, Ping)
}
//

//
//

// type Message {
//   Ping(respond_with: process.Subject(String))
// }

// pub fn ping() {
//   let assert Ok(actor) =
//     actor.new_with_initialiser(100, fn(_) {
//       let subj = process.new_subject()
//       let selector = process.new_selector() |> process.select(subj)

//       actor.initialised(Nil)
//       |> actor.returning(subj)
//       |> actor.selecting(selector)
//       |> Ok
//     })
//     |> actor.on_message(fn(state, msg: Message) {
//       case msg {
//         Ping(respond_with) -> {
//           echo "Pong"
//           process.send(respond_with, "pong")
//           actor.continue(state)
//         }
//       }
//     })
//     |> actor.start

//   echo process.call(actor.data, 500, Ping)
// }

// pub fn main() -> Nil {
//   ping()

//   Nil
// }

//
//

// type Message {
//   Ping(respond_with: process.Subject(String))
// }

// pub fn ping() {
//   let subj = process.new_subject()
//   let selector = process.new_selector() |> process.select(subj)

//   let assert Ok(_) =
//     actor.new_with_initialiser(100, fn(_) {
//       actor.initialised([""])
//       |> actor.selecting(selector)
//       |> Ok
//     })
//     |> actor.on_message(fn(state, msg: Message) {
//       case msg {
//         Ping(respond_with) -> {
//           echo "Pong"
//           process.send(respond_with, "pong")
//           actor.continue(state)
//         }
//       }
//     })
//     |> actor.start

//   echo process.call(subj, 500, Ping)
// }
