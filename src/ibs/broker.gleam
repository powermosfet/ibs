import carotte
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/time/duration
import ibs/amqp_returns
import ibs/config.{type Config}
import ibs/lookup
import ibs/pms
import ibs/runtime

pub type Failure {
  Fatal(String)
  Retry(String)
}

type Delivery {
  Delivery(carotte.Payload, carotte.Deliver)
}

type Session {
  Session(
    client: carotte.Client,
    input: carotte.Channel,
    output: carotte.Channel,
    inbox: process.Subject(Delivery),
  )
}

pub fn run(config: Config) -> Nil {
  process.trap_exits(True)
  let name = process.new_name("ibs_consumers")
  io.println("Iterative Barcode Searcher starting")
  connect(config, name, config.retry_initial_ms)
}

fn connect(
  config: Config,
  name: process.Name(carotte.ConsumerSupervisorMessage),
  delay: Int,
) -> Nil {
  let client_config =
    carotte.ClientConfig(
      ..carotte.default_client(),
      host: config.host,
      port: config.port,
      username: config.username,
      password: config.password,
      virtual_host: config.vhost,
      heartbeat: duration.seconds(config.heartbeat_seconds),
      connection_timeout: duration.milliseconds(config.connection_timeout_ms),
    )
  case carotte.start(client_config) {
    Error(_) -> {
      // Library error details may include connection parameters/credentials.
      io.println_error("RabbitMQ connection failed; retrying")
      process.sleep(delay)
      connect(config, name, lookup.next_delay(delay, config.retry_max_ms))
    }
    Ok(client) -> {
      let outcome = case setup(client, config, name) {
        Error(error) -> Error(error)
        Ok(session) -> {
          io.println("RabbitMQ ready; consuming scanned barcodes")
          consume(session, config)
        }
      }
      let _ = carotte.close(client)
      // Dispose of all old consumer children before reusing the name. Each
      // session has a fresh subject, preventing stale delivery-tag reuse.
      case process.subject_owner(process.named_subject(name)) {
        Ok(pid) -> {
          let monitor = process.monitor(pid)
          process.kill(pid)
          let _ =
            process.new_selector()
            |> process.select_specific_monitor(monitor, fn(_) { Nil })
            |> process.selector_receive(5000)
          process.demonitor_process(monitor)
        }
        Error(_) -> Nil
      }
      // All session processes are closed; discard their queued deliveries,
      // returns and trapped exits before opening the next session.
      process.flush_messages()
      case outcome {
        Error(Fatal(message)) -> {
          io.println_error(message)
          runtime.halt(1)
        }
        Error(Retry(message)) -> {
          io.println_error(
            "RabbitMQ session ended: " <> message <> "; reconnecting",
          )
          process.sleep(delay)
          connect(config, name, lookup.next_delay(delay, config.retry_max_ms))
        }
        Ok(_) -> Nil
      }
    }
  }
}

fn setup(
  client: carotte.Client,
  config: Config,
  name: process.Name(carotte.ConsumerSupervisorMessage),
) -> Result(Session, Failure) {
  use input <- result.try(
    carotte.open_channel(client)
    |> result.map_error(fn(_) { Retry("open input channel") }),
  )
  use output <- result.try(
    carotte.open_channel(client)
    |> result.map_error(fn(_) { Retry("open output channel") }),
  )
  use _ <- result.try(
    list.try_each(
      [config.input_queue, config.shopping_queue, config.missing_queue],
      fn(queue) { declare(output, queue) },
    ),
  )
  use _ <- result.try(
    carotte.set_qos(input, 1, False)
    |> result.map_error(fn(_) { Retry("set QoS") }),
  )
  amqp_returns.watch(output)
  use _ <- result.try(
    carotte.start_transaction(output)
    |> result.map_error(fn(_) { Retry("start output transaction") }),
  )
  use consumer <- result.try(
    carotte.start_consumer(name)
    |> result.map_error(fn(_) { Retry("start consumer") }),
  )
  let inbox = process.new_subject()
  use _ <- result.try(
    carotte.subscribe_with_options(
      consumer,
      channel: input,
      queue: config.input_queue,
      options: [carotte.AutoAck(False)],
      callback: fn(payload, delivery) {
        process.send(inbox, Delivery(payload, delivery))
      },
    )
    |> result.map_error(fn(_) { Retry("subscribe") }),
  )
  Ok(Session(client, input, output, inbox))
}

fn declare(channel: carotte.Channel, name: String) -> Result(Nil, Failure) {
  carotte.declare_queue(
    carotte.QueueConfig(..carotte.default_queue(name), durable: True),
    channel,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    case error {
      carotte.QueuePreconditionFailed(_) ->
        Fatal(
          "Queue declaration mismatch for "
          <> name
          <> "; expected durable, nonexclusive, non-auto-deleting",
        )
      carotte.QueueAccessRefused(_) ->
        Fatal("Queue access refused for " <> name)
      carotte.QueueResourceLocked(_) -> Fatal("Queue is locked: " <> name)
      _ -> Retry("queue declaration failed")
    }
  })
}

fn healthy(session: Session, config: Config) -> Bool {
  carotte.is_connected(session.client)
  && result.is_ok(carotte.queue_status(session.input, queue: config.input_queue))
}

fn consume(session: Session, config: Config) -> Result(Nil, Failure) {
  case process.receive(session.inbox, 1000) {
    Ok(Delivery(payload, delivery)) -> {
      use outcome <- result.try(resolve(
        payload.payload,
        session,
        config,
        config.retry_initial_ms,
      ))
      use _ <- result.try(case outcome {
        lookup.Found(_) -> Ok(Nil)
        lookup.Missing(_) -> notify(session, config, config.retry_initial_ms)
      })
      use _ <- result.try(publish(session.output, config, outcome))
      use _ <- result.try(
        carotte.ack_single(session.input, delivery.delivery_tag)
        |> result.map_error(fn(_) { Retry("input acknowledgement failed") }),
      )
      io.println(case outcome {
        lookup.Found(_) -> "Product sent to shopping-list queue"
        lookup.Missing(_) -> "Barcode sent to missing queue"
      })
      consume(session, config)
    }
    Error(_) ->
      case healthy(session, config) {
        True -> consume(session, config)
        False -> Error(Retry("connection or input channel lost"))
      }
  }
}

fn resolve(
  payload: BitArray,
  session: Session,
  config: Config,
  delay: Int,
) -> Result(lookup.Outcome, Failure) {
  let outcome =
    lookup.barcode(payload)
    |> result.try(fn(barcode) { lookup.fetch(config, barcode) })
  case outcome {
    Ok(outcome) -> Ok(outcome)
    Error(error) -> {
      io.println_error("Lookup retry: " <> lookup.describe(error))
      process.sleep(delay)
      case healthy(session, config) {
        True ->
          resolve(
            payload,
            session,
            config,
            lookup.next_delay(delay, config.retry_max_ms),
          )
        False -> Error(Retry("connection or input channel lost during lookup"))
      }
    }
  }
}

fn notify(
  session: Session,
  config: Config,
  delay: Int,
) -> Result(Nil, Failure) {
  case pms.send(config) {
    Ok(_) -> Ok(Nil)
    Error(message) -> {
      io.println_error("Notification retry: " <> message)
      process.sleep(delay)
      case healthy(session, config) {
        True ->
          notify(session, config, lookup.next_delay(delay, config.retry_max_ms))
        False ->
          Error(Retry("connection or input channel lost during notification"))
      }
    }
  }
}

pub fn publish(
  channel: carotte.Channel,
  config: Config,
  outcome: lookup.Outcome,
) -> Result(Nil, Failure) {
  let #(queue, body, content_type) = case outcome {
    lookup.Found(body) -> #(config.shopping_queue, body, "application/json")
    lookup.Missing(barcode) -> #(config.missing_queue, barcode, "text/plain")
  }
  use _ <- result.try(
    carotte.publish(
      channel: channel,
      exchange: "",
      routing_key: queue,
      payload: bit_array.from_string(body),
      options: [
        carotte.Persistent(True),
        carotte.Mandatory(True),
        carotte.ContentType(content_type),
      ],
    )
    |> result.map_error(fn(_) { Retry("output publication failed") }),
  )
  use _ <- result.try(
    carotte.commit_transaction(channel)
    |> result.map_error(fn(_) { Retry("output commit failed or uncertain") }),
  )
  case amqp_returns.returned() {
    True -> Error(Retry("output was returned as unroutable"))
    False -> Ok(Nil)
  }
}
