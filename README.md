# Iterative Barcode Searcher

A Gleam service that consumes scanned barcodes from RabbitMQ, looks up each
product through a REST API, and routes the result to a shopping-list queue or a
missing-barcode queue. It runs on Erlang/OTP and is packaged as a Nix flake.

## Run

RabbitMQ and the product API must be available separately. The lookup API must
return HTTP **200 with a JSON object**, or **404** when the product is unknown.

```sh
export PRODUCT_LOOKUP_URL_TEMPLATE='http://localhost:8080/products/{barcode}'
nix run path:.
```

Or build and run the installed executable:

```sh
nix build path:.
./result/bin/iterative-barcode-searcher
```

The package includes the matching Erlang runtime and compiled dependencies;
Gleam, Rebar3, and dependency downloads are not needed at runtime. Flake outputs
support `x86_64-linux` and `aarch64-linux`.

To use the example environment file:

```sh
cp .env.example .env
# Edit .env for your services, then export its settings:
set -a
. ./.env
set +a
nix run path:.
```

The service reads environment variables directly; it does not load `.env` files
automatically. Stop it with Ctrl-C or SIGTERM. The connection closes when the
Erlang VM exits, allowing unfinished scans to be redelivered.

## Message flow

```text
scanned_barcodes (plain text)
          |
          v
GET PRODUCT_LOOKUP_URL_TEMPLATE
          |
          +-- 200 JSON object --> shopping_list_items (original JSON body)
          |
          +-- 404 -------------> missing_barcodes (cleaned plain-text barcode)
```

Input is UTF-8 text. Surrounding whitespace and scanner line endings are
trimmed; leading zeros are preserved. Barcodes are percent-encoded before
replacing `{barcode}` in the URL, supporting both path and query templates.
For example, ` 001234\r\n` requests `/products/001234`.

Successful product bodies are validated as JSON objects and forwarded unchanged,
including unknown fields and formatting. No envelope or extra fields are added.
The output content type is `application/json` for products and `text/plain` for
missing barcodes. Every scan is processed independently, including repeats.

The missing queue is only an output. This version does not recheck missing
barcodes; another component or a manual action can resubmit them to the input.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `PRODUCT_LOOKUP_URL_TEMPLATE` | **Required** | HTTP(S) GET URL with exactly one `{barcode}` placeholder |
| `RABBITMQ_HOST` | `localhost` | Broker hostname |
| `RABBITMQ_PORT` | `5672` | AMQP port |
| `RABBITMQ_USERNAME` | `guest` | Broker username |
| `RABBITMQ_PASSWORD` | `guest` | Broker password; empty passwords are allowed |
| `RABBITMQ_VHOST` | `/` | Broker virtual host |
| `BARCODE_INPUT_QUEUE` | `scanned_barcodes` | Scanned text input |
| `SHOPPING_LIST_QUEUE` | `shopping_list_items` | Product JSON output |
| `MISSING_BARCODES_QUEUE` | `missing_barcodes` | Missing barcode text output |
| `HTTP_TIMEOUT_MS` | `5000` | HTTP request timeout |
| `RABBITMQ_CONNECTION_TIMEOUT_MS` | `10000` | Connection establishment timeout |
| `RABBITMQ_HEARTBEAT_SECONDS` | `30` | AMQP heartbeat interval |
| `RETRY_INITIAL_DELAY_MS` | `1000` | Initial retry delay |
| `RETRY_MAX_DELAY_MS` | `30000` | Maximum exponential-backoff delay |

Queue names must be distinct and nonempty. Ports must be between 1 and 65535,
timeouts and delays must be positive, and the initial retry delay must not
exceed the maximum. URL templates cannot contain credentials or fragments.
Invalid configuration exits with status 1 before connecting.

The service declares durable, nonexclusive, non-auto-deleting queues and
publishes persistent messages using the default exchange. Existing queues must
have compatible declarations; a mismatch or denied queue access exits with a
clear error. Broker policies may choose queue types. The connecting user needs
permission to declare, consume, and publish to the configured queues.

V1 uses plain AMQP and an unauthenticated REST API. HTTPS uses certificate
verification, and redirects are not followed. Logs go to standard output/error;
application logs omit passwords and product bodies.

## Delivery and retries

Only one input is in flight (manual acknowledgement, prefetch 1). Publication
uses a separate transaction channel: commit the persistent output, check for
mandatory returns, then acknowledge the input. A failed, unroutable, or uncertain
publication leaves the scan unacknowledged. After a broker/channel failure the
service reconnects and declares its queues again, using fresh delivery tags.

Delivery is **at least once**. A failure after publishing but before the input
acknowledgement can produce duplicate output. Consumers must tolerate this;
the service does not deduplicate scans because repeats can be intentional.

HTTP failures, statuses other than 200/404, invalid JSON/non-object responses,
and invalid or empty input are retried indefinitely with capped exponential
backoff. A failing scan blocks later scans. An invalid barcode cannot repair
itself: stop the service and remove or correct that message through broker
administration. Missing products (404) are completed successfully rather than
retried. Broker acknowledgement timeouts may cause channel closure and
redelivery during a long retry sequence; the service reconnects in that case.

Carotte 5.0.0 provides the Gleam AMQP API. Because it does not expose mandatory
return notifications, `ibs/amqp_returns` binds to the dependency's Erlang return
handler API. Application source is entirely Gleam; dependencies use Erlang.
That binding depends on Carotte's pinned channel representation and should be
revalidated when upgrading it.

## Develop and verify

```sh
nix develop path:.
gleam test
gleam format --check src test
gleam run
```

```sh
nix flake check path:.
```

The package check compiles an Erlang shipment offline, checks formatting, and
runs unit tests. Dependencies are fetched with SHA-256 checksums from
`manifest.toml`; Nixpkgs is pinned by `flake.lock`.

The integration check boots a NixOS VM containing RabbitMQ and a controllable
HTTP stub. It exercises routing, repeated scans, URL encoding, blocking retries,
malformed responses, timeouts, unroutable output, broker restart, shutdown
redelivery, and incompatible declarations. Running VM tests requires a Linux
host with virtualization support. To build only the application, use `nix build`.

After changing Gleam dependencies, run `gleam deps download` to update the
manifest and rerun `nix flake check`. The Nix dependency set is derived directly
from that manifest.
