import app
import constants
import gleam/erlang/process
import gleam/otp/static_supervisor

pub fn main() -> Nil {
  app.start()

  process.sleep_forever()
}
