import birdie
import drift/effect
import drift/record
import drift/record/format
import gleam/bytes_tree
import gleam/list
import gleam/option.{None}
import gleam/string
import spoke/core.{Connect, Perform, TransportEstablished}
import spoke/mqtt
import spoke/packet
import spoke/packet/client/incoming as client_in
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub type Recorder =
  record.Recorder(core.State, core.Input, core.Output, String, effect.Formatter)

pub fn default() -> Recorder {
  from_options(mqtt.connect_with_id(0, "my-client"))
}

pub fn default_connected() -> Recorder {
  default()
  |> record.input(Perform(Connect(False, None)))
  |> record.input(TransportEstablished)
  |> received(server_out.ConnAck(Ok(packet.SessionNotPresent)))
  |> record.flush("connect and handshake")
}

pub fn from_options(options: mqtt.ConnectOptions(_)) -> Recorder {
  record.new(core.new_state(options), core.handle_input, formatter())
}

pub fn from_state(state: String) -> Recorder {
  let options = mqtt.connect_with_id(0, "my-client")
  let assert Ok(state) = core.restore_state(options, state)
  record.new(state, core.handle_input, formatter())
}

pub fn received(recorder: Recorder, packet: server_out.Packet) -> Recorder {
  let data = server_out.encode_packet(packet)
  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  record.input(recorder, input)
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
  record.input(recorder, input)
}

pub fn snap(recorder: Recorder, title: String) -> Nil {
  birdie.snap(record.to_log(recorder), title)
}

fn formatter() -> format.Formatter(
  effect.Formatter,
  record.Message(core.Input, core.Output),
) {
  use formatter, msg <- format.stateful(effect.new_formatter())

  case msg {
    record.Input(input) -> format_input(formatter, input)
    record.Output(output) -> format_output(formatter, output)
  }
}

fn format_input(
  formatter: effect.Formatter,
  input: core.Input,
) -> #(effect.Formatter, String) {
  case input {
    Perform(command) ->
      case command {
        core.Disconnect(complete) -> {
          use complete <- format.map(formatter, effect.inspect, complete)
          format_record("Disconnect", [complete])
        }
        core.GetPendingPublishes(complete) -> {
          use complete <- format.map(formatter, effect.inspect, complete)
          format_record("GetPendingPublishes", [complete])
        }
        core.Subscribe(requests, complete) -> {
          use complete <- format.map(formatter, effect.inspect, complete)
          format_record("Subscribe", [string.inspect(requests), complete])
        }
        core.Unsubscribe(topics, complete) -> {
          use complete <- format.map(formatter, effect.inspect, complete)
          format_record("Unsubscribe", [string.inspect(topics), complete])
        }
        core.WaitForPublishesToFinish(complete, timeout) -> {
          use complete <- format.map(formatter, effect.inspect, complete)
          format_record("WaitForPublishesToFinish", [
            complete,
            string.inspect(timeout),
          ])
        }
        other -> #(formatter, string.inspect(other))
      }
    core.ReceivedData(data) -> {
      let result = case client_in.decode_packets(data) {
        Error(_) -> format_record("ReceivedData", [string.inspect(data)])
        Ok(#([packet], <<>>)) -> string.inspect(ReceivedPacket(packet))
        Ok(#(packets, <<>>)) -> string.inspect(ReceivedPackets(packets))
        Ok(#(packets, leftover)) ->
          string.inspect(ReceivedPartial(packets, leftover))
      }
      #(formatter, result)
    }
    core.Timeout(_) -> panic as "Should only be used in tick!"
    other -> #(formatter, string.inspect(other))
  }
}

fn format_output(
  formatter: effect.Formatter,
  output: core.Output,
) -> #(effect.Formatter, String) {
  case output {
    core.PublishesCompleted(action) -> {
      let assert Ok(action) =
        effect.inspect_action(formatter, action, string.inspect)
      #(formatter, format_record("PublishesCompleted", [action]))
    }
    core.ReportStateAtDisconnect(action) -> {
      let assert Ok(action) =
        effect.inspect_action(formatter, action, string.inspect)
      #(formatter, format_record("ReportStateAtDisconnect", [action]))
    }
    core.ReturnPendingPublishes(action) -> {
      let assert Ok(action) =
        effect.inspect_action(formatter, action, string.inspect)
      #(formatter, format_record("ReturnPendingPublishes", [action]))
    }
    core.SubscribeCompleted(action) -> {
      let assert Ok(action) =
        effect.inspect_action(formatter, action, string.inspect)
      #(formatter, format_record("SubscribeCompleted", [action]))
    }
    core.UnsubscribeCompleted(action) -> {
      let assert Ok(action) =
        effect.inspect_action(formatter, action, string.inspect)
      #(formatter, format_record("UnsubscribeCompleted", [action]))
    }
    core.SendData(data) -> {
      let assert Ok(#(packet, <<>>)) =
        server_in.decode_packet(bytes_tree.to_bit_array(data))
      #(formatter, string.inspect(SendData(packet)))
    }
    other -> #(formatter, string.inspect(other))
  }
}

fn format_record(name: String, args: List(String)) -> String {
  name <> "(" <> string.join(args, ", ") <> ")"
}

type FormatHelper {
  SendData(server_in.Packet)
  ReceivedPacket(client_in.Packet)
  ReceivedPackets(List(client_in.Packet))
  ReceivedPartial(List(client_in.Packet), BitArray)
}
