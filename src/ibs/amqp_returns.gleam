import carotte.{type Channel}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process

// Carotte 5.0.0 sends mandatory publishes but does not expose basic.return.
// These declarations use the dependency's public Erlang API without adding
// Erlang application source. Channel is {channel, Pid} in this pinned version.
@external(erlang, "erlang", "element")
fn channel_pid(index: Int, channel: Channel) -> process.Pid

@external(erlang, "amqp_channel", "register_return_handler")
fn register(pid: process.Pid, handler: process.Pid) -> Dynamic

pub fn watch(channel: Channel) -> Nil {
  let _ = register(channel_pid(2, channel), process.self())
  Nil
}

pub fn is_return(message: Dynamic) -> Bool {
  let decoder = {
    use tag <- decode.subfield([0, 0], atom.decoder())
    decode.success(atom.to_string(tag) == "basic.return")
  }
  case decode.run(message, decoder) {
    Ok(value) -> value
    Error(_) -> False
  }
}

// The channel sends basic.return before replying to tx.commit. Both messages
// originate from that same Erlang process, so after commit replies the return
// is already in our mailbox. Drain only untyped messages; delivery subjects
// are handled by the service loop, outside this publication step.
pub fn returned() -> Bool {
  let selector = process.new_selector() |> process.select_other(is_return)
  drain(selector, False)
}

fn drain(selector: process.Selector(Bool), found: Bool) -> Bool {
  case process.selector_receive(selector, 0) {
    Ok(value) -> drain(selector, found || value)
    Error(_) -> found
  }
}
