import constants
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
      let batch = sliced_queue |> list.take(up_to: constants.batch_size)
      let rest = sliced_queue |> list.drop(up_to: constants.batch_size)

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
