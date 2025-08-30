import gleam/io
import postal_code/data_parser

pub fn main() -> Nil {
  let parser = data_parser.new()
  let data = data_parser.parse(parser)
  io.println(data)
}
