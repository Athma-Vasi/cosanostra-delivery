import gleam/io
import gleam/list
import gleam/result
import gleam/string
import postal_code/data_parser

pub fn data_parser_test() {
  let parser = data_parser.new()
  let data = data_parser.parse(parser)
  let split =
    data
    |> string.split(on: "\n")
    |> list.first
    |> result.unwrap("splitting error")
    |> string.trim

  let header =
    "USPS\tGEOID\tALAND\tAWATER\tALAND_SQMI\tAWATER_SQMI\tINTPTLAT\tINTPTLONG"
  assert header == split
}
