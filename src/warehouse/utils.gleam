import constants
import gleam/int
import gleam/list

fn batch_and_slice_queue_helper(
  batches: List(List(items)),
  sliced_queue: List(items),
  counter,
  available_actors_count,
) {
  case counter == available_actors_count {
    True -> #(batches, sliced_queue)

    False -> {
      let batch =
        sliced_queue |> list.take(up_to: constants.receiver_batch_size)
      let rest = sliced_queue |> list.drop(up_to: constants.receiver_batch_size)

      batch_and_slice_queue_helper(
        [batch, ..batches],
        rest,
        counter + 1,
        available_actors_count,
      )
    }
  }
}

pub fn batch_and_slice_queue(
  package_queue: List(items),
  available_actors_count,
) -> #(List(List(items)), List(items)) {
  batch_and_slice_queue_helper([], package_queue, 0, available_actors_count)
}

pub fn get_first_batch(items) {
  items
  |> list.index_fold(from: [], with: fn(acc, item, idx) {
    case idx == 0 {
      True -> item
      False -> acc
    }
  })
}

pub fn maybe_crash() -> Nil {
  let crash_factor = int.random(100)
  echo "Crash factor: " <> int.to_string(crash_factor)
  case crash_factor > constants.crash_factor_limit {
    True -> {
      echo "Uncle Enzo is not pleased... delivery deadline missed!"
      panic as "Panic! At The Warehouse"
    }
    False -> Nil
  }
}
