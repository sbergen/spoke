import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/list
import spoke/core/internal/session.{type Session}
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/client/outgoing

type ConnectionState {
  NotConnected
  Connecting(options: packet.ConnectOptions)
  Connected(leftover_data: BitArray)
}

pub opaque type State {
  State(session: Session, connection: ConnectionState)
}

pub type OperationId =
  Int

pub type Action {
  Connect(packet.ConnectOptions)
  Disconnect
}

pub type Input {
  Tick
  TransportEstablished
  TransportFailed(String)
  ReceivedData(BitArray)
  Perform(Action)
}

pub type Output {
  OpenTransport
  CloseTransport
  SendData(BytesTree)
  ReceivedMessage(packet.MessageData)
  ReceivedConnectResponse(packet.ConnAckResult)
}

pub type Next {
  Next(state: State, outputs: List(Output))
}

pub fn new() -> State {
  State(session.new(False), NotConnected)
}

pub fn tick(state: State, time: Int, input: Input) -> Next {
  case input {
    ReceivedData(data) -> receive(state, data)
    Tick -> todo
    TransportEstablished -> transport_established(state)
    TransportFailed(_) -> todo
    Perform(action) ->
      case action {
        Connect(options) -> connect(state, options)
        Disconnect -> disconnect(state)
      }
  }
}

fn connect(state: State, options: packet.ConnectOptions) -> Next {
  use <- bool.guard(when: state.connection != NotConnected, return: noop(state))

  // [MQTT-3.1.2-6]
  // If CleanSession is set to 1,
  // the Client and Server MUST discard any previous Session and start a new one.
  // This Session lasts as long as the Network Connection.
  // State data associated with this Session MUST NOT be reused in any subsequent Session.
  let session = case
    options.clean_session || session.is_ephemeral(state.session)
  {
    True -> session.new(options.clean_session)
    False -> state.session
  }

  Next(State(session, Connecting(options)), [OpenTransport])
}

fn disconnect(state: State) -> Next {
  Next(State(..state, connection: NotConnected), [
    send(outgoing.Disconnect),
    CloseTransport,
  ])
}

fn transport_established(state: State) -> Next {
  // TODO: Handle errors
  let assert Connecting(options) = state.connection

  // TODO: Start pings
  let connect_packet = outgoing.Connect(options)
  Next(State(..state, connection: Connected(<<>>)), [send(connect_packet)])
}

fn receive(state: State, data: BitArray) -> Next {
  // TODO: Handle errors
  let assert Connected(leftover_data) = state.connection
  let data = bit_array.append(leftover_data, data)
  let assert Ok(#(packets, leftover_data)) = incoming.decode_all(data)
  let state = State(..state, connection: Connected(leftover_data))

  let Next(state, outputs) = {
    use Next(state, outputs), packet <- list.fold(packets, Next(state, []))

    case packet {
      incoming.ConnAck(result) -> handle_connack(state, result, outputs)
      incoming.PingResp -> todo
      incoming.PubAck(_) -> todo
      incoming.PubComp(_) -> todo
      incoming.PubRec(_) -> todo
      incoming.PubRel(_) -> todo
      incoming.Publish(_) -> todo
      incoming.SubAck(_, _) -> todo
      incoming.UnsubAck(_) -> todo
    }
  }

  Next(state, list.reverse(outputs))
}

fn handle_connack(
  state: State,
  result: packet.ConnAckResult,
  outputs: List(Output),
) -> Next {
  let outputs = [ReceivedConnectResponse(result), ..outputs]

  // If a server sends a CONNACK packet containing a non-zero return code
  // it MUST then close the Network Connection.
  // We play it safe and close it anyway.
  case result {
    Ok(_) -> Next(state, outputs)
    Error(_) ->
      Next(State(..state, connection: NotConnected), [CloseTransport, ..outputs])
  }
}

fn noop(state: State) -> Next {
  Next(state, [])
}

fn send(packet: outgoing.Packet) -> Output {
  // TODO: Error handling
  let assert Ok(data) = outgoing.encode_packet(packet)
  SendData(data)
}
