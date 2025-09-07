import gleam/dict
import gleam/io
import warehouse/warehouse

pub fn main() -> Nil {
  warehouse.start()
  let table = warehouse.random_batch(10)
  table
  |> dict.each(fn(key, value) {
    io.println("key: " <> key <> "\t" <> "value: " <> value)
  })
}
