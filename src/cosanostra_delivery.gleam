import gleam/erlang/process
import warehouse/warehouse

pub fn main() -> Nil {
  warehouse.start()
  process.sleep_forever()
}
