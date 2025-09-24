import app
import gleam/erlang/process

pub fn main() -> Nil {
  app.start()
  process.sleep_forever()
}
