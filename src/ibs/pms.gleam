import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import ibs/config.{type Config}

pub fn memo(bpd_url: String) -> String {
  json.object([
    #("subject", json.string("Unknown barcode")),
    #("content", json.string(bpd_url)),
  ])
  |> json.to_string
}

pub fn send(config: Config) -> Result(Nil, String) {
  use req <- result.try(
    request.to(
      "http://"
      <> config.pms_host
      <> ":"
      <> int.to_string(config.pms_port)
      <> "/memo",
    )
    |> result.map_error(fn(_) { "invalid PMS URL" }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(memo(config.bpd_url))
  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(config.http_timeout_ms)
    |> httpc.follow_redirects(False)
    |> httpc.dispatch(req)
    |> result.map_error(fn(_) { "PMS request failed or timed out" }),
  )
  case response.status >= 200 && response.status < 300 {
    True -> Ok(Nil)
    False ->
      Error("unexpected PMS HTTP status " <> int.to_string(response.status))
  }
}
