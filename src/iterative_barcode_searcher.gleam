import gleam/io
import ibs/broker
import ibs/config
import ibs/runtime

pub fn main() {
  case config.load() {
    Error(message) -> {
      io.println_error("Configuration error: " <> message)
      runtime.halt(1)
    }
    Ok(config) -> broker.run(config)
  }
}
