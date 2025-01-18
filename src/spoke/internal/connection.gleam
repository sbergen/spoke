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

import gleam/bool
import gleam/dynamic
import gleam/erlang/process.{type Selector, type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import spoke/internal/packet
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/transport.{type ByteChannel, type EncodedChannel}

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
  let child =
    process.start(linked: True, running: fn() {
      let messages = process.new_subject()
      let connect = process.new_subject()
      process.send(ack_subject, #(messages, connect))
      establish_channel(messages, connect, clean_session, auth, will)
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
  Received(#(BitArray, Result(List(incoming.Packet), String)))
  ProcessReceived(incoming.Packet)
  SendPing
  ShutDown(Option(String))
}

type State {
  State(
    self: Subject(Message),
    selector: Selector(Message),
    updates: Subject(Update),
    keep_alive_ms: Int,
    server_timeout_ms: Int,
    connection_state: ConnectionState,
  )
}

type ConnectionState {
  /// Connect packet has been sent, but we haven't gotten a connack
  ConnectingToServer(channel: EncodedChannel, disconnect_timer: process.Timer)
  Connected(
    channel: EncodedChannel,
    /// Timer for sending the next ping request
    ping_timer: process.Timer,
    /// Timer for shutting down the connection if a ping is not responded to in time
    shutdown_timer: Option(process.Timer),
  )
}

fn establish_channel(
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
  let channel = transport.encode_channel(channel)

  let disconnect_timer =
    process.send_after(
      mailbox,
      config.server_timeout_ms,
      ShutDown(Some("Connect timed out")),
    )
  let connection_state = ConnectingToServer(channel, disconnect_timer)
  let state =
    State(
      mailbox,
      next_selector(channel, <<>>, mailbox),
      config.updates,
      config.keep_alive_ms,
      config.server_timeout_ms,
      connection_state,
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
    Received(#(new_channel_state, packets)) ->
      handle_receive(state, new_channel_state, packets)
    ProcessReceived(packet) -> process_packet(state, packet)
    Send(packet) -> send_from_session(state, packet)
    SendPing -> send_ping(state)
    ShutDown(reason) -> shut_down(state, reason)
  }

  run(state)
}

fn shut_down(state: State, reason: Option(String)) -> State {
  get_channel(state).shutdown()
  stop(reason)
}

/// Sends a packet coming directly from the session
fn send_from_session(state: State, packet: outgoing.Packet) -> State {
  use state <- send_packet_or_stop(state, packet)
  state
}

fn handle_receive(
  state: State,
  new_conn_state: BitArray,
  packets: Result(List(incoming.Packet), String),
) -> State {
  use packets <- ok_or_exit(packets, fn(e) {
    "Transport channel error while receiving: " <> e
  })

  // Schedule the packets to be processed,
  // to atomically update the actor state.
  list.each(packets, fn(packet) {
    process.send(state.self, ProcessReceived(packet))
  })

  let selector = next_selector(get_channel(state), new_conn_state, state.self)
  State(..state, selector:)
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
    ConnectingToServer(channel, disconnect_timer) -> {
      process.cancel_timer(disconnect_timer)

      // Send the connack to the session, so that it knows the result
      process.send(state.updates, ReceivedPacket(incoming.ConnAck(status)))

      case status {
        Ok(_session_present) -> {
          let connection_state =
            Connected(channel, start_ping_timeout(state), None)
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
    Connected(channel, ping, disconnect) -> {
      // We should also not be waiting for a ping response,
      // but in case scheduling is delayed (or we have short timeouts in tests),
      // this might still happen.
      // In this case, just keep waiting for the current disconnect timeout,
      // and skip this send.
      case disconnect, process.cancel_timer(ping) {
        _, process.Cancelled(time_remaining) ->
          stop_abnormal(
            "A ping scheduling overlap happened, previous time remaining: "
            <> string.inspect(time_remaining),
          )
        Some(_), _ ->
          stop_abnormal(
            "A ping was scheduled while waiting for a ping response",
          )
        None, _ -> {
          use state <- send_packet_or_stop(state, outgoing.PingReq)
          let disconnect =
            process.send_after(
              state.self,
              state.server_timeout_ms,
              ShutDown(Some("Ping timeout")),
            )
          State(
            ..state,
            connection_state: Connected(channel, ping, Some(disconnect)),
          )
        }
      }
    }
    ConnectingToServer(..) ->
      stop_abnormal("Trying to send ping while still connecting to server")
  }
}

fn handle_pingresp(state: State) -> State {
  case state.connection_state {
    Connected(channel, ping, Some(shutdown_timer)) -> {
      process.cancel_timer(shutdown_timer)
      State(..state, connection_state: Connected(channel, ping, None))
    }
    Connected(_, _, None) ->
      stop_abnormal("No shutdown timer active when receiving PingResp")
    ConnectingToServer(..) -> stop_abnormal("Got unexpected PingResp")
  }
}

/// Selects the next incoming packet from the channel & any messages sent to self.
fn next_selector(
  channel: EncodedChannel,
  channel_state: BitArray,
  self: Subject(Message),
) -> process.Selector(Message) {
  process.map_selector(channel.selecting_next(channel_state), Received(_))
  |> process.selecting(self, function.identity)
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
  case state.connection_state {
    ConnectingToServer(channel, ..) -> {
      // Don't start ping if connection has not yet finished
      use _ <- result.try(channel.send(packet))
      Ok(state)
    }
    Connected(channel, ping, disconnect) -> {
      use _ <- result.try(channel.send(packet))
      process.cancel_timer(ping)
      let ping = start_ping_timeout(state)
      Ok(State(..state, connection_state: Connected(channel, ping, disconnect)))
    }
  }
}

fn start_ping_timeout(state: State) -> process.Timer {
  process.send_after(state.self, state.keep_alive_ms, SendPing)
}

fn get_channel(state: State) -> EncodedChannel {
  case state.connection_state {
    Connected(channel, ..) -> channel
    ConnectingToServer(channel, ..) -> channel
  }
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
