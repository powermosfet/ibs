import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import gleam/uri
import ibs/config.{type Config}

pub type Outcome {
  Found(body: String)
  Missing(barcode: String)
}

pub type LookupError {
  InvalidBarcode
  InvalidProduct
  HttpStatus(Int)
  HttpFailure
}

pub fn barcode(payload: BitArray) -> Result(String, LookupError) {
  use text <- result.try(
    bit_array.to_string(payload) |> result.map_error(fn(_) { InvalidBarcode }),
  )
  let cleaned = string.trim(text)
  case cleaned {
    "" -> Error(InvalidBarcode)
    _ -> Ok(cleaned)
  }
}

pub fn url(template: String, barcode: String) -> String {
  let encoded = uri.percent_encode(barcode) |> string.replace("+", "%2B")
  string.replace(template, "{barcode}", encoded)
}

pub fn classify(
  status: Int,
  body: String,
  barcode: String,
) -> Result(Outcome, LookupError) {
  case status {
    404 -> Ok(Missing(barcode))
    200 -> {
      use _ <- result.try(
        json.parse(body, decode.dict(decode.string, decode.dynamic))
        |> result.map_error(fn(_) { InvalidProduct }),
      )
      Ok(Found(body))
    }
    other -> Error(HttpStatus(other))
  }
}

pub fn fetch(config: Config, barcode: String) -> Result(Outcome, LookupError) {
  use req <- result.try(
    request.to(url(config.lookup_template, barcode))
    |> result.map_error(fn(_) { HttpFailure }),
  )
  let req = request.set_header(req, "accept", "application/json")
  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(config.http_timeout_ms)
    |> httpc.follow_redirects(False)
    |> httpc.dispatch(req)
    |> result.map_error(fn(_) { HttpFailure }),
  )
  classify(response.status, response.body, barcode)
}

pub fn describe(error: LookupError) -> String {
  case error {
    InvalidBarcode -> "invalid or empty UTF-8 barcode"
    InvalidProduct -> "response is not a JSON object"
    HttpStatus(status) -> "unexpected HTTP status " <> int.to_string(status)
    HttpFailure -> "HTTP request failed or timed out"
  }
}

pub fn next_delay(current: Int, maximum: Int) -> Int {
  int.min(current * 2, maximum)
}
