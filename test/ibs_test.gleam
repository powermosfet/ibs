import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/json
import gleam/list
import gleam/result
import gleeunit/should
import ibs/amqp_returns
import ibs/config
import ibs/lookup
import ibs/pms

fn environment(
  values: List(#(String, String)),
) -> fn(String) -> Result(String, Nil) {
  fn(key) {
    list.find(values, fn(pair) { pair.0 == key })
    |> result.map(fn(pair) { pair.1 })
  }
}

const template = "http://localhost:8080/products/{barcode}"

fn settings(values: List(#(String, String))) -> Result(config.Config, String) {
  config.from_env(
    environment([
      #("PRODUCT_LOOKUP_URL_TEMPLATE", template),
      #("BPD_URL", "http://localhost:8082/"),
      ..values
    ]),
  )
}

pub fn default_configuration_test() {
  let config = settings([]) |> should.be_ok
  config.port |> should.equal(5672)
  config.pms_host |> should.equal("localhost")
  config.pms_port |> should.equal(8081)
  config.bpd_url |> should.equal("http://localhost:8082/")
  config.input_queue |> should.equal("scanned_barcodes")
  config.retry_initial_ms |> should.equal(1000)
}

pub fn environment_overrides_test() {
  let config =
    settings([
      #("RABBITMQ_HOST", "broker"),
      #("RABBITMQ_PORT", "5673"),
      #("RABBITMQ_PASSWORD", ""),
      #("HTTP_TIMEOUT_MS", "250"),
      #("PMS_HOST", "pms"),
      #("PMS_PORT", "9000"),
    ])
    |> should.be_ok
  config.host |> should.equal("broker")
  config.port |> should.equal(5673)
  config.password |> should.equal("")
  config.http_timeout_ms |> should.equal(250)
  config.pms_host |> should.equal("pms")
  config.pms_port |> should.equal(9000)
}

pub fn required_url_test() {
  config.from_env(environment([])) |> should.be_error
  config.from_env(environment([#("PRODUCT_LOOKUP_URL_TEMPLATE", template)]))
  |> should.be_error
}

pub fn invalid_numbers_test() {
  list.each(["", "0", "-1", "garbage", "65536"], fn(value) {
    settings([#("RABBITMQ_PORT", value)]) |> should.be_error
    settings([#("PMS_PORT", value)]) |> should.be_error
  })
  settings([#("HTTP_TIMEOUT_MS", "0")]) |> should.be_error
  settings([#("RETRY_INITIAL_DELAY_MS", "40000")]) |> should.be_error
}

pub fn notification_configuration_test() {
  list.each(
    ["", " ", "pms/path", "user:pass@pms", "pms?query", "pms:90"],
    fn(host) { settings([#("PMS_HOST", host)]) |> should.be_error },
  )
  list.each(
    [
      "",
      "ftp://example.org",
      "http://user:pass@example.org",
      "http://example.org/#fragment",
    ],
    fn(url) { config.validate_url(url, "BPD_URL") |> should.be_error },
  )
  config.validate_url("https://bpd.example.org/?view=unknown", "BPD_URL")
  |> should.be_ok
}

pub fn notification_payload_test() {
  let url = "https://bpd.example.org/?view=unknown&label=\"new\""
  let decoder = {
    use subject <- decode.field("subject", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(subject, content))
  }
  pms.memo(url)
  |> json.parse(decoder)
  |> should.equal(Ok(#("Unknown barcode", url)))
}

pub fn queue_configuration_test() {
  settings([#("BARCODE_INPUT_QUEUE", " ")]) |> should.be_error
  settings([#("SHOPPING_LIST_QUEUE", "scanned_barcodes")]) |> should.be_error
  settings([#("MISSING_BARCODES_QUEUE", "shopping_list_items")])
  |> should.be_error
}

pub fn url_templates_test() {
  list.each([template, "https://example.org/find?barcode={barcode}"], fn(url) {
    config.validate_template(url) |> should.be_ok
  })
  list.each(
    [
      "",
      "http://localhost/products",
      "ftp://localhost/{barcode}",
      "http://localhost/{barcode}/{barcode}",
      "http://user:pass@localhost/{barcode}",
      "http://localhost/{barcode}#fragment",
      "http:///{barcode}",
      "http://localhost/bad path/{barcode}",
    ],
    fn(url) { config.validate_template(url) |> should.be_error },
  )
}

pub fn barcode_normalization_test() {
  lookup.barcode(<<" 0012345\r\n">>) |> should.equal(Ok("0012345"))
  lookup.barcode(<<"ABC-12">>) |> should.equal(Ok("ABC-12"))
  lookup.barcode(<<" \r\n">>) |> should.equal(Error(lookup.InvalidBarcode))
  lookup.barcode(<<255>>) |> should.equal(Error(lookup.InvalidBarcode))
}

pub fn url_encoding_test() {
  lookup.url(template, "00/A B?&+#é")
  |> should.equal("http://localhost:8080/products/00%2FA%20B%3F%26%2B%23%C3%A9")
}

pub fn json_forwarded_verbatim_test() {
  let body = " {\"name\": \"Milk\", \"unknown\": [1, null, {\"x\": true}]} \n"
  lookup.classify(200, body, "001") |> should.equal(Ok(lookup.Found(body)))
  lookup.classify(200, "{}", "001") |> should.equal(Ok(lookup.Found("{}")))
}

pub fn invalid_products_test() {
  list.each(
    ["", "null", "[]", "123", "\"milk\"", "{invalid}", "{\"name\":1} trailing"],
    fn(body) {
      lookup.classify(200, body, "001")
      |> should.equal(Error(lookup.InvalidProduct))
    },
  )
}

pub fn response_classification_test() {
  lookup.classify(404, "not JSON", "001")
  |> should.equal(Ok(lookup.Missing("001")))
  list.each([201, 204, 301, 400, 401, 429, 500, 503], fn(status) {
    lookup.classify(status, "{}", "001")
    |> should.equal(Error(lookup.HttpStatus(status)))
  })
}

pub fn exponential_backoff_test() {
  lookup.next_delay(1000, 30_000) |> should.equal(2000)
  lookup.next_delay(16_000, 30_000) |> should.equal(30_000)
  lookup.next_delay(30_000, 30_000) |> should.equal(30_000)
}

pub fn mandatory_return_detection_test() {
  dynamic.array([
    dynamic.array([
      atom.to_dynamic(atom.create("basic.return")),
      dynamic.int(312),
      dynamic.string("NO_ROUTE"),
      dynamic.string(""),
      dynamic.string("missing"),
    ]),
    dynamic.array([dynamic.string("message"), dynamic.string("body")]),
  ])
  |> amqp_returns.is_return
  |> should.be_true
  dynamic.array([
    atom.to_dynamic(atom.create("EXIT")),
    dynamic.string("other"),
    dynamic.string("normal"),
  ])
  |> amqp_returns.is_return
  |> should.be_false
}
