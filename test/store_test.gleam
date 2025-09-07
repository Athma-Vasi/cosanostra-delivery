import gleam/erlang/process
import postal_code/store

pub fn store_test() {
  let store_name = process.new_name("parser_store")
  let assert Ok(_store) = store.new(store_name)
}
