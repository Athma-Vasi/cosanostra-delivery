import gleam/erlang/process

pub fn main() -> Nil {
  let main_subject = process.new_subject()
  let receive_subject = process.new_subject()
  let _ = process.spawn(fn() { start(main_subject) })

  let assert Ok(process) = process.receive(main_subject, 2000)
  run_async(process, Query(receive_subject, "Hello"))

  let _ = get_result(receive_subject) |> echo

  process.sleep_forever()
}

type Query {
  Query(from: process.Subject(String), query: String)
}

fn start(main_subject: process.Subject(process.Subject(Query))) -> Nil {
  let send_subject = process.new_subject()
  process.send(main_subject, send_subject)
  loop(send_subject)
}

fn loop(subject: process.Subject(Query)) -> Nil {
  case process.receive(subject, 5000) {
    Ok(query) -> {
      let result = run_query(query)
      process.send(query.from, result)
    }
    Error(_) -> loop(subject)
  }

  loop(subject)
}

fn run_query(query: Query) -> String {
  // process.sleep(2000)
  query.query <> " result"
}

fn run_async(subject: process.Subject(string), query: string) -> Nil {
  process.send(subject, query)
}

fn get_result(subject: process.Subject(b)) -> Result(b, String) {
  case process.receive(subject, 5000) {
    Ok(result) -> Ok(result)
    Error(_) -> Error("timeout")
  }
}
