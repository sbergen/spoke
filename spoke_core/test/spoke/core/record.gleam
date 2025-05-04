import birdie
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import spoke/core.{type Timestamp}
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub opaque type Recorder {
  Recorder(
    state: core.State,
    next_tick: Option(Timestamp),
    time: Timestamp,
    log: String,
  )
}

pub fn new() -> Recorder {
  Recorder(core.new(), None, 0, "")
}

pub fn time_advance(recorder: Recorder, duration: Int) -> Recorder {
  let time = recorder.time + duration
  let recorder = {
    let log = recorder.log <> "  ... " <> string.inspect(time) <> " ms:\n"
    Recorder(..recorder, log:, time:)
  }

  case recorder.next_tick {
    Some(next) if next <= time ->
      recorder |> input(core.Tick) |> assert_ticks_exhausted
    _ -> recorder
  }
}

fn assert_ticks_exhausted(recorder: Recorder) -> Recorder {
  case recorder.next_tick {
    Some(next) if next <= recorder.time -> {
      let log =
        recorder.log
        <> "!!!!! Next tick at "
        <> string.inspect(next)
        <> " !!!!!\n"
      Recorder(..recorder, log:)
    }
    _ -> recorder
  }
}

pub fn input(recorder: Recorder, input: core.Input) -> Recorder {
  input_preformatted(recorder, input, string.inspect(input))
}

pub fn received(recorder: Recorder, packet: server_out.Packet) -> Recorder {
  let assert Ok(data) = server_out.encode_packet(packet)
  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  input_preformatted(recorder, input, string.inspect(ReceivedPacket(packet)))
}

pub fn received_many(
  recorder: Recorder,
  packets: List(server_out.Packet),
) -> Recorder {
  let data = {
    use acc, packet <- list.fold(packets, bytes_tree.new())
    let assert Ok(data) = server_out.encode_packet(packet)
    bytes_tree.concat([acc, data])
  }

  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  input_preformatted(recorder, input, string.inspect(ReceivedPackets(packets)))
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
  let log = recorder.log <> "  --> " <> input_string <> "\n"

  case core.update(recorder.state, recorder.time, input) {
    Ok(#(state, next_tick, outputs)) -> {
      let log =
        log
        <> "<--   "
        <> string.inspect(list.map(outputs, format_output))
        <> "\n"
      Recorder(..recorder, state:, log:, next_tick:)
    }

    Error(error) -> {
      let log = log <> "  !!  " <> error <> "\n"
      Recorder(..recorder, log:)
    }
  }
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
  ReceivedPackets(List(server_out.Packet))
}
