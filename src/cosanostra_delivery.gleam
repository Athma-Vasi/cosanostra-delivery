import app
import gleam/erlang/process

pub fn main() -> Nil {
  let assert Ok(_application) = app.start()
  echo "APP STARTED"
  process.sleep_forever()
}
