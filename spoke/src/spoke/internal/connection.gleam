//// A MQTT session can span over multiple connections.
//// This module defines an actor that lives for the duration of one connection.
//// While most packets will be controlled by the session,
//// the following are handled by the connection:
//// - `Connect` and `ConnAck`
//// - `PinReq` and `PingResp`
//// as these don't interact with the session.
//// `ConnAck` is also sent to the session as a FYI on the status.
//// 
//// Killing the connection actor on protocol violations
//// simplifies handling e.g. invalid packets,
//// which should immediately close the channel
//// according to the MQTT specification.

import gleam/bit_array
import gleam/bool
import gleam/dynamic
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import spoke/internal/transport.{type ByteChannel}
import spoke/packet
import spoke/packet/client/incoming
import spoke/packet/client/outgoing

pub opaque type Connection {
  Connection(subject: Subject(Message), updates: Selector(Update))
}

pub type Disconnect {
  GracefulDisconnect
  AbnormalDisconnect(String)
}

pub type Update {
  Disconnected(Disconnect)
  ReceivedPacket(incoming.Packet)
}

/// Starts the connection.
/// The connection will be alive until there is a channel error,
/// protocol violation, or explicitly disconnected.
/// The ConnAck packet will be sent as an update if/when connected.
pub fn connect(
  create_channel: fn() -> Result(transport.ByteChannel, String),
  client_id: String,
  clean_session: Bool,
  keep_alive_ms: Int,
  server_timeout_ms: Int,
  auth: Option(packet.AuthOptions),
  will: Option(#(packet.MessageData, packet.QoS)),
) -> Result(Connection, String) {
  // Start linked, as this *really* shouldn't fail
  let ack_subject = process.new_subject()
  let parent = process.self()
  let child =
    process.start(linked: True, running: fn() {
      let messages = process.new_subject()
      let connect = process.new_subject()
      process.send(ack_subject, #(messages, connect))
      establish_channel(parent, messages, connect, clean_session, auth, will)
    })

  // Start monitoring and unlink
  let monitor = process.monitor_process(child)
  process.unlink(child)

  let updates = process.new_subject()
  let config =
    Config(create_channel, updates, client_id, keep_alive_ms, server_timeout_ms)

  use #(messages, connect) <- result.try(
    process.receive(ack_subject, server_timeout_ms)
    |> result.map_error(fn(_) {
      process.kill(child)
      "Starting connection process timed out"
    }),
  )

  process.send(connect, config)

  let updates =
    process.new_selector()
    |> process.selecting(updates, function.identity)
    |> process.selecting_process_down(monitor, fn(down) {
      let reason = down.reason
      let normal = dynamic.from(process.Normal)
      let killed = dynamic.from(process.Killed)

      let kind = {
        use <- bool.guard(reason == normal, GracefulDisconnect)
        use <- bool.guard(reason == killed, AbnormalDisconnect("Killed"))
        AbnormalDisconnect(string.inspect(reason))
      }
      Disconnected(kind)
    })

  Ok(Connection(messages, updates))
}

// TODO: Call this from the client
// pub fn received_data(
//   connection: Connection,
//   data: Result(BitArray, String),
// ) -> Connection {
//   process.send(connection.subject, Received(data))
//   connection
// }

/// Gets the updates `Selector` from the connection
pub fn updates(connection: Connection) -> Selector(Update) {
  connection.updates
}

/// Sends the given packet
pub fn send(connection: Connection, packet: outgoing.Packet) -> Nil {
  process.send(connection.subject, Send(packet))
}

/// Disconnects the connection cleanly
pub fn shutdown(connection: Connection) {
  process.send(connection.subject, ShutDown(None))
}

type Config {
  Config(
    create_channel: fn() -> Result(ByteChannel, String),
    updates: Subject(Update),
    client_id: String,
    keep_alive_ms: Int,
    server_timeout_ms: Int,
  )
}

type Message {
  Send(outgoing.Packet)
  Received(Result(BitArray, String))
  ProcessReceived(incoming.Packet)
  SendPing
  ShutDown(Option(String))
}

type State {
  State(
    self: Subject(Message),
    // "Constant" selector without channel messages
    base_selector: Selector(Message),
    // Current selector, including channel messages
    selector: Selector(Message),
    updates: Subject(Update),
    keep_alive_ms: Int,
    server_timeout_ms: Int,
    connection_state: ConnectionState,
    channel: ByteChannel,
    leftover_data: BitArray,
  )
}

type ConnectionState {
  /// Connect packet has been sent, but we haven't gotten a connack
  ConnectingToServer(disconnect_timer: process.Timer)
  Connected(
    /// Timer for sending the next ping request
    ping_timer: process.Timer,
    /// Timer for shutting down the connection if a ping is not responded to in time
    shutdown_timer: Option(process.Timer),
  )
}

fn establish_channel(
  parent: Pid,
  mailbox: Subject(Message),
  connect: Subject(Config),
  clean_session: Bool,
  auth: Option(packet.AuthOptions),
  will: Option(#(packet.MessageData, packet.QoS)),
) -> Nil {
  // If we can't receive in time, the parent is very stuck, so dying is fine
  let assert Ok(config) = process.receive(connect, 1000)

  use channel <- ok_or_exit(config.create_channel(), fn(e) {
    "Failed to establish connection to server: " <> e
  })

  let disconnect_timer =
    process.send_after(
      mailbox,
      config.server_timeout_ms,
      ShutDown(Some("Connect timed out")),
    )
  let connection_state = ConnectingToServer(disconnect_timer)

  let parent_monitor = process.monitor_process(parent)
  let base_selector =
    process.new_selector()
    |> process.selecting_process_down(parent_monitor, fn(_) { ShutDown(None) })
    |> process.selecting(mailbox, function.identity)

  let state =
    State(
      mailbox,
      base_selector,
      next_selector(channel, base_selector),
      config.updates,
      config.keep_alive_ms,
      config.server_timeout_ms,
      connection_state,
      channel,
      <<>>,
    )

  let connect_options =
    packet.ConnectOptions(
      clean_session:,
      client_id: config.client_id,
      keep_alive_seconds: config.keep_alive_ms / 1000,
      auth:,
      will:,
    )

  use state <- ok_or_exit(
    send_packet(state, outgoing.Connect(connect_options)),
    fn(e) { "Error sending connect packet to server: " <> e },
  )

  run(state)
}

fn ok_or_exit(
  result: Result(a, e),
  make_reason: fn(e) -> String,
  continuation: fn(a) -> b,
) -> b {
  case result {
    Ok(a) -> continuation(a)
    Error(e) -> stop_abnormal(make_reason(e))
  }
}

fn run(state: State) -> Nil {
  let message = process.select_forever(state.selector)
  let state = case message {
    Received(data) -> handle_receive(state, data)
    ProcessReceived(packet) -> process_packet(state, packet)
    Send(packet) -> send_from_session(state, packet)
    SendPing -> send_ping(state)
    ShutDown(reason) -> shut_down(state, reason)
  }

  run(state)
}

fn shut_down(state: State, reason: Option(String)) -> State {
  state.channel.shutdown()
  stop(reason)
}

/// Sends a packet coming directly from the session
fn send_from_session(state: State, packet: outgoing.Packet) -> State {
  use state <- send_packet_or_stop(state, packet)
  state
}

fn handle_receive(state: State, data: Result(BitArray, String)) -> State {
  use data <- ok_or_exit(data, fn(e) {
    "Transport channel error while receiving: " <> e
  })

  let data = bit_array.append(state.leftover_data, data)
  use #(packets, leftover_data) <- ok_or_exit(incoming.decode_all(data), fn(e) {
    "Decoding error while receiving: " <> string.inspect(e)
  })

  // Schedule the packets to be processed,
  // to atomically update the actor state.
  list.each(packets, fn(packet) {
    process.send(state.self, ProcessReceived(packet))
  })

  let selector = next_selector(state.channel, state.base_selector)
  State(..state, selector:, leftover_data:)
}

fn process_packet(state: State, packet: incoming.Packet) -> State {
  case packet {
    incoming.ConnAck(data) -> handle_connack(state, data)
    incoming.PingResp -> handle_pingresp(state)
    packet -> send_to_session(state, packet)
  }
}

fn send_to_session(state: State, packet: incoming.Packet) -> State {
  process.send(state.updates, ReceivedPacket(packet))
  state
}

fn handle_connack(state: State, status: packet.ConnAckResult) -> State {
  case state.connection_state {
    ConnectingToServer(disconnect_timer) -> {
      process.cancel_timer(disconnect_timer)

      // Send the connack to the session, so that it knows the result
      process.send(state.updates, ReceivedPacket(incoming.ConnAck(status)))

      case status {
        Ok(_session_present) -> {
          let connection_state = Connected(start_ping_timeout(state), None)
          State(..state, connection_state:)
        }
        Error(_) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection
          // The status was was sent above, so make this a "normal" shutdown
          shut_down(state, None)
        }
      }
    }
    Connected(..) ->
      shut_down(state, Some("Got ConnAck while already connected"))
  }
}

fn send_ping(state: State) -> State {
  case state.connection_state {
    Connected(ping, disconnect) -> {
      // In case we send a packet while the ping timer has expired,
      // but this hasn't run yet (message is in mailbox),
      // we'll have a new timer already started here.
      // Cancel any possible timer, as we are sending a ping now!
      process.cancel_timer(ping)

      case disconnect {
        Some(_) ->
          stop_abnormal(
            "A ping was scheduled while waiting for a ping response",
          )
        None -> {
          use state <- send_packet_or_stop(state, outgoing.PingReq)
          let disconnect =
            process.send_after(
              state.self,
              state.server_timeout_ms,
              ShutDown(Some("Ping timeout")),
            )
          State(..state, connection_state: Connected(ping, Some(disconnect)))
        }
      }
    }
    ConnectingToServer(..) ->
      stop_abnormal("Trying to send ping while still connecting to server")
  }
}

fn handle_pingresp(state: State) -> State {
  case state.connection_state {
    Connected(ping, Some(shutdown_timer)) -> {
      process.cancel_timer(shutdown_timer)
      State(..state, connection_state: Connected(ping, None))
    }
    Connected(_, None) ->
      stop_abnormal("No shutdown timer active when receiving PingResp")
    ConnectingToServer(..) -> stop_abnormal("Got unexpected PingResp")
  }
}

/// Selects the next incoming packet from the channel & any messages sent to self.
fn next_selector(
  channel: ByteChannel,
  base: Selector(Message),
) -> process.Selector(Message) {
  process.map_selector(channel.selecting_next(), Received)
  |> process.merge_selector(base)
}

fn send_packet_or_stop(
  state: State,
  packet: outgoing.Packet,
  if_success: fn(State) -> State,
) -> State {
  use state <- ok_or_exit(send_packet(state, packet), fn(e) {
    "Transport channel error '"
    <> e
    <> "' while sending packet "
    <> string.inspect(packet)
  })

  if_success(state)
}

// Clients are allowed to send further Control Packets immediately after sending a CONNECT Packet;
// Clients need not wait for a CONNACK Packet to arrive from the Server.
// If the Server rejects the CONNECT, it MUST NOT process any data sent by the Client after the CONNECT Packet
//
// Non normative comment
// Clients typically wait for a CONNACK Packet, However,
// if the Client exploits its freedom to send Control Packets before it receives a CONNACK,
// it might simplify the Client implementation as it does not have to police the connected state.
// The Client accepts that any data that it sends before it receives a CONNACK packet from the Server
// will not be processed if the Server rejects the connection.
fn send_packet(state: State, packet: outgoing.Packet) -> Result(State, String) {
  use data <- result.try(
    outgoing.encode_packet(packet)
    |> result.map_error(fn(e) { "Encode error: " <> string.inspect(e) }),
  )

  use _ <- result.try(state.channel.send(data))

  case state.connection_state {
    ConnectingToServer(..) -> {
      // Don't start ping if connection has not yet finished
      Ok(state)
    }
    Connected(ping, disconnect) -> {
      process.cancel_timer(ping)
      let ping = start_ping_timeout(state)
      Ok(State(..state, connection_state: Connected(ping, disconnect)))
    }
  }
}

fn start_ping_timeout(state: State) -> process.Timer {
  process.send_after(state.self, state.keep_alive_ms, SendPing)
}

fn stop_abnormal(reason: String) {
  stop(Some(reason))
}

fn stop(reason: Option(String)) -> anything {
  case reason {
    None -> process.send_exit(process.self())
    Some(reason) -> process.send_abnormal_exit(process.self(), reason)
  }

  panic as "We should be dead by now"
}
