import birdie
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string
import spoke/core.{type Timestamp}
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub opaque type Recorder {
  Recorder(state: core.State, time: Timestamp, log: String)
}

pub fn new() -> Recorder {
  Recorder(core.new(), 0, "")
}

pub fn time_advance(recorder: Recorder, duration: Int) -> Recorder {
  let time = recorder.time + duration
  let log = recorder.log <> "... " <> string.inspect(time) <> " ms:\n"
  Recorder(..recorder, log:, time:)
}

pub fn input(recorder: Recorder, input: core.Input) -> Recorder {
  input_preformatted(recorder, input, string.inspect(input))
}

pub fn received(recorder: Recorder, packet: server_out.Packet) -> Recorder {
  let assert Ok(data) = server_out.encode_packet(packet)
  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  input_preformatted(recorder, input, string.inspect(ReceivedPacket(packet)))
}

pub fn flush(recorder: Recorder, what: String) -> Recorder {
  Recorder(..recorder, log: "<flushed " <> what <> ">\n")
}

pub fn snap(recorder: Recorder, title: String) -> Nil {
  birdie.snap(string.trim_end(recorder.log), title)
}

fn input_preformatted(
  recorder: Recorder,
  input: core.Input,
  input_string: String,
) -> Recorder {
  let core.Next(state, outputs) =
    core.tick(recorder.state, recorder.time, input)
  let log = recorder.log <> "  --> " <> input_string <> "\n"
  let log =
    log <> "<--   " <> string.inspect(list.map(outputs, format_output)) <> "\n"
  Recorder(..recorder, state:, log:)
}

fn format_output(output: core.Output) -> Dynamic {
  case output {
    core.SendData(data) -> {
      let assert Ok(#(packet, <<>>)) =
        server_in.decode_packet(bytes_tree.to_bit_array(data))
      dynamic.from(SendData(packet))
    }
    other -> dynamic.from(other)
  }
}

type FormatHelper {
  SendData(server_in.Packet)
  ReceivedPacket(server_out.Packet)
}
