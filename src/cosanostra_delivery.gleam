import gleam/dict
import gleam/io
import warehouse/package
import warehouse/warehouse

pub fn main() -> Nil {
  warehouse.start()
  let table = package.random_batch(10)
  table
  |> dict.each(fn(key, value) {
    io.println("key: " <> key <> "\t" <> "value: " <> value)
  })
}
