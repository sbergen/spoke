import birdie
import drift
import drift/record
import gleam/bytes_tree
import gleam/function
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import spoke/core.{Connect, Handle, Perform, TransportEstablished}
import spoke/mqtt
import spoke/packet
import spoke/packet/client/incoming as client_in
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub type Recorder =
  record.Recorder(core.State, core.Input, core.Output, String)

pub fn default() -> Recorder {
  from_options(mqtt.connect_with_id(0, "my-client"))
  |> record.input(Perform(core.SubscribeToUpdates(record.discard())))
}

pub fn default_connected() -> Recorder {
  default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(Handle(TransportEstablished))
  |> received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.flush("connect and handshake")
}

pub fn from_options(options: mqtt.ConnectOptions(_)) -> Recorder {
  record.new(core.new_state(options), core.handle_input, formatter, None)
}

//pub fn from_state(state: String) -> Recorder {
//  let options = mqtt.connect_with_id(0, "my-client")
//  let assert Ok(state) = core.restore_state(options, state)
//  record.new(state, core.handle_input, formatter, None)
//}

pub fn received(recorder: Recorder, packet: server_out.Packet) -> Recorder {
  let data = server_out.encode_packet(packet)
  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  record.input(recorder, Handle(input))
}

pub fn received_many(
  recorder: Recorder,
  packets: List(server_out.Packet),
) -> Recorder {
  let data = {
    use acc, packet <- list.fold(packets, bytes_tree.new())
    let data = server_out.encode_packet(packet)
    bytes_tree.concat([acc, data])
  }

  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  record.input(recorder, Handle(input))
}

pub fn snap(recorder: Recorder, title: String) -> Nil {
  birdie.snap(record.to_log(recorder), title)
}

fn formatter(msg: record.Message(core.Input, core.Output, String)) -> String {
  case msg {
    record.Input(input) -> format_input(input)
    record.Output(output) -> format_output(output)
    record.Error(error) -> error
  }
}

fn format_input(input: core.Input) -> String {
  case input {
    Perform(command) ->
      case command {
        core.SubscribeToUpdates(publish) ->
          "Subscribe to updates " <> format_effect(publish)

        core.UnsubscribeFromUpdates(publish) ->
          "Unsubscribe from updates " <> format_effect(publish)

        core.Disconnect(complete) -> "Disconnect " <> format_effect(complete)

        core.GetPendingPublishes(complete) ->
          "Get pending publishes " <> format_effect(complete)

        core.Subscribe(requests, complete) ->
          "Subscribe "
          <> format_effect(complete)
          <> format_list(requests, fn(req) {
            let mqtt.SubscribeRequest(topic, qos) = req
            topic <> " - " <> string.inspect(qos)
          })

        core.Unsubscribe(topics, complete) ->
          "Unsubscribe "
          <> format_effect(complete)
          <> format_list(topics, function.identity)

        core.WaitForPublishesToFinish(complete, timeout) ->
          "Wait for publishes "
          <> format_effect(complete)
          <> " (timeout "
          <> string.inspect(timeout)
          <> ")"

        Connect(clean_session, will) ->
          "Connect - clean session: "
          <> string.inspect(clean_session)
          <> ", will: "
          <> string.inspect(will)

        core.PublishMessage(data) -> {
          let mqtt.PublishData(topic, payload, qos, retain) = data
          "Publish to "
          <> string.inspect(topic)
          <> ": "
          <> string.inspect(payload)
          <> " @ "
          <> string.inspect(qos)
          <> ", retain: "
          <> string.inspect(retain)
        }
      }

    Handle(core.ReceivedData(data)) -> {
      "Received: "
      <> case client_in.decode_packets(data) {
        Error(e) -> string.inspect(data) <> ", error: " <> string.inspect(e)
        Ok(#([packet], <<>>)) -> string.inspect(packet)
        Ok(#(packets, leftover)) -> {
          let received = format_list(packets, string.inspect)
          case leftover {
            <<>> -> received
            data -> received <> "\n  Left over data: " <> string.inspect(data)
          }
        }
      }
    }
    core.Timeout(_) -> panic as "Should only be used in tick!"
    Handle(TransportEstablished) -> "Transport established"
    Handle(core.TransportClosed) -> "Transport closed"
    Handle(core.TransportFailed(e)) -> "Transport failed: " <> e
  }
}

fn format_output(output: core.Output) -> String {
  case output {
    core.PublishesCompleted(action) ->
      "Wait for publishes " <> format_action(action, string.inspect)

    core.CompleteDisconnect(action) ->
      "Disconnect " <> format_action(action, string.inspect)

    core.ReturnPendingPublishes(action) ->
      "Pending publishes " <> format_action(action, int.to_string)

    core.SubscribeCompleted(action) ->
      "Subscribe "
      <> format_action(action, fn(result) {
        case result {
          Error(e) -> string.inspect(e)
          Ok(subscriptions) -> {
            use sub <- format_list(subscriptions)
            case sub {
              mqtt.FailedSubscription(topic) -> topic <> " - Failed!"
              mqtt.SuccessfulSubscription(topic, qos) ->
                topic <> " - " <> string.inspect(qos)
            }
          }
        }
      })

    core.UnsubscribeCompleted(action) ->
      "Unsubscribe " <> format_action(action, string.inspect)

    core.SendData(data) -> {
      let assert Ok(#(packet, <<>>)) =
        server_in.decode_packet(bytes_tree.to_bit_array(data))
      "Send: " <> string.inspect(packet)
    }
    core.Publish(action) ->
      "Publish to "
      <> format_effect(action.effect)
      <> ": "
      <> case action.argument {
        mqtt.ConnectionStateChanged(change) -> string.inspect(change)
        update -> string.inspect(update)
      }

    core.CloseTransport -> "Close transport"
    core.OpenTransport -> "Open transport"
  }
}

fn format_effect(e: drift.Effect(a)) -> String {
  "#" <> string.inspect(drift.effect_id(e))
}

fn format_action(a: drift.Action(a), inspect: fn(a) -> String) -> String {
  "#"
  <> string.inspect(drift.effect_id(a.effect))
  <> " completed: "
  <> inspect(a.argument)
}

fn format_list(items: List(a), inspect: fn(a) -> String) -> String {
  case items {
    [] -> ""
    items ->
      "\n"
      <> items
      |> list.map(fn(val) { "  * " <> inspect(val) })
      |> string.join("\n")
  }
}
