// import app
// import constants
import app
import gleam/erlang/process

// import gleam/otp/static_supervisor
// import navigator/sup as navigator_sup
// import warehouse/package
// import warehouse/receiver
// import warehouse/sup as warehouse_sup

pub fn main() -> Nil {
  app.start()
  process.sleep_forever()
}
