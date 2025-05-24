import birdie
import drift/record
import gleam/bytes_tree
import gleam/dynamic
import gleam/list
import gleam/string
import spoke/core
import spoke/mqtt
import spoke/packet/server/incoming as server_in
import spoke/packet/server/outgoing as server_out

pub type Recorder =
  record.Recorder(core.State, core.Input, core.Output, String)

pub fn default() -> Recorder {
  from_options(mqtt.connect_with_id(0, "my-client"))
}

pub fn from_options(options: mqtt.ConnectOptions(_)) -> Recorder {
  record.new(core.new_state(options), core.handle_input, format_output)
}

pub fn received(recorder: Recorder, packet: server_out.Packet) -> Recorder {
  let assert Ok(data) = server_out.encode_packet(packet)
  let input = core.ReceivedData(bytes_tree.to_bit_array(data))
  record.input_preformatted(
    recorder,
    input,
    string.inspect(ReceivedPacket(packet)),
  )
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
  record.input_preformatted(
    recorder,
    input,
    string.inspect(ReceivedPackets(packets)),
  )
}

pub fn snap(recorder: Recorder, title: String) -> Nil {
  birdie.snap(record.to_log(recorder), title)
}

// TODO: these forward declarations aren't great :/

pub fn input(recorder: Recorder, input: core.Input) -> Recorder {
  record.input(recorder, input)
}

pub fn flush(recorder: Recorder, what: String) -> Recorder {
  record.flush(recorder, what)
}

pub fn time_advance(recorder: Recorder, duration: Int) -> Recorder {
  record.time_advance(recorder, duration)
}

// end TODO

fn format_output(output: core.Output) -> String {
  case output {
    core.SendData(data) -> {
      let assert Ok(#(packet, <<>>)) =
        server_in.decode_packet(bytes_tree.to_bit_array(data))
      dynamic.from(SendData(packet))
    }
    other -> dynamic.from(other)
  }
  |> string.inspect
}

type FormatHelper {
  SendData(server_in.Packet)
  ReceivedPacket(server_out.Packet)
  ReceivedPackets(List(server_out.Packet))
}
