import constants
import gleam/erlang/process
import gleam/otp/static_supervisor
import playground/sup

pub fn main() -> Nil {
  // app.start()
  sup.start_overmind()
  process.sleep_forever()
}
