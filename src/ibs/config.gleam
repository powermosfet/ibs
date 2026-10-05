import envoy
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Config {
  Config(
    host: String,
    port: Int,
    username: String,
    password: String,
    vhost: String,
    input_queue: String,
    shopping_queue: String,
    missing_queue: String,
    lookup_template: String,
    http_timeout_ms: Int,
    connection_timeout_ms: Int,
    heartbeat_seconds: Int,
    retry_initial_ms: Int,
    retry_max_ms: Int,
  )
}

pub fn load() -> Result(Config, String) {
  from_env(envoy.get)
}

pub fn from_env(
  get: fn(String) -> Result(String, Nil),
) -> Result(Config, String) {
  use host <- result.try(text(get, "RABBITMQ_HOST", "localhost"))
  use port <- result.try(number(get, "RABBITMQ_PORT", 5672))
  use username <- result.try(text(get, "RABBITMQ_USERNAME", "guest"))
  let password = get("RABBITMQ_PASSWORD") |> result.unwrap("guest")
  use vhost <- result.try(text(get, "RABBITMQ_VHOST", "/"))
  use input <- result.try(text(get, "BARCODE_INPUT_QUEUE", "scanned_barcodes"))
  use shopping <- result.try(text(
    get,
    "SHOPPING_LIST_QUEUE",
    "shopping_list_items",
  ))
  use missing <- result.try(text(
    get,
    "MISSING_BARCODES_QUEUE",
    "missing_barcodes",
  ))
  use template <- result.try(
    get("PRODUCT_LOOKUP_URL_TEMPLATE")
    |> result.map_error(fn(_) { "PRODUCT_LOOKUP_URL_TEMPLATE is required" }),
  )
  use timeout <- result.try(number(get, "HTTP_TIMEOUT_MS", 5000))
  use connection_timeout <- result.try(number(
    get,
    "RABBITMQ_CONNECTION_TIMEOUT_MS",
    10_000,
  ))
  use heartbeat <- result.try(number(get, "RABBITMQ_HEARTBEAT_SECONDS", 30))
  use initial <- result.try(number(get, "RETRY_INITIAL_DELAY_MS", 1000))
  use maximum <- result.try(number(get, "RETRY_MAX_DELAY_MS", 30_000))
  use _ <- result.try(validate_template(template))
  case
    port <= 65_535
    && initial <= maximum
    && list.unique([input, shopping, missing]) == [input, shopping, missing]
  {
    False ->
      Error(
        "Port must be at most 65535, retry initial delay must not exceed maximum, and queue names must be distinct",
      )
    True ->
      Ok(Config(
        host,
        port,
        username,
        password,
        vhost,
        input,
        shopping,
        missing,
        template,
        timeout,
        connection_timeout,
        heartbeat,
        initial,
        maximum,
      ))
  }
}

fn text(
  get: fn(String) -> Result(String, Nil),
  key: String,
  default: String,
) -> Result(String, String) {
  let value = get(key) |> result.unwrap(default)
  case string.trim(value) == "" {
    True -> Error(key <> " must not be empty")
    False -> Ok(value)
  }
}

fn number(
  get: fn(String) -> Result(String, Nil),
  key: String,
  default: Int,
) -> Result(Int, String) {
  case get(key) {
    Error(_) -> Ok(default)
    Ok(value) ->
      case int.parse(value) {
        Ok(n) if n > 0 -> Ok(n)
        _ -> Error(key <> " must be a positive integer")
      }
  }
}

pub fn validate_template(template: String) -> Result(Nil, String) {
  let error =
    "PRODUCT_LOOKUP_URL_TEMPLATE must be an HTTP(S) URL with exactly one {barcode} placeholder and no credentials or fragment"
  case string.split(template, "{barcode}") {
    [_, _] -> {
      let sample = string.replace(template, "{barcode}", "012345")
      use parsed <- result.try(
        uri.parse(sample) |> result.map_error(fn(_) { error }),
      )
      use _ <- result.try(
        request.to(sample) |> result.map_error(fn(_) { error }),
      )
      case parsed {
        uri.Uri(
          scheme: Some(scheme),
          host: Some(host),
          userinfo: None,
          fragment: None,
          ..,
        )
          if scheme == "http" || scheme == "https"
        ->
          case host != "" && !string.contains(template, " ") {
            True -> Ok(Nil)
            False -> Error(error)
          }
        _ -> Error(error)
      }
    }
    _ -> Error(error)
  }
}
