//// A MQTT session can span over multiple connections.
//// This module defines an actor that lives for the duration of one connection.
//// While most packets will be controlled by the session,
//// the following are handled by the connection:
//// - `Connect` and `ConnAck`
//// - `PinReq` and `PingResp`
//// as these don't interact with the session.
//// 
//// Killing the connection actor on protocol violations
//// simplifies handling e.g. invalid packets,
//// which should immediately close the channel
//// according to the MQTT specification.

import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import spoke/internal/packet
import spoke/internal/packet/client/incoming
import spoke/internal/packet/client/outgoing
import spoke/internal/transport.{type ChannelResult}
import spoke/internal/transport/channel.{type EncodedChannel}

pub opaque type Connection {
  Connection(subject: Subject(Message))
}

// TODO: Add auth, will, etc
/// Starts the connection.
/// The connection will be alive until there is a channel error,
/// protocol violation, or explicitly disconnected.
/// Returns the connection handle and a subject for supervision on success.
pub fn connect(
  create_channel: fn() -> transport.ByteChannel,
  incoming: Subject(incoming.Packet),
  client_id: String,
  keep_alive_ms: Int,
  server_timeout_ms: Int,
) -> Result(Connection, String) {
  actor.start_spec(actor.Spec(
    fn() {
      init(
        create_channel,
        incoming,
        client_id,
        keep_alive_ms,
        server_timeout_ms,
      )
    },
    server_timeout_ms,
    run,
  ))
  |> result.map(Connection)
  |> result.map_error(fn(e) {
    case e {
      actor.InitCrashed(_) -> "Connection process crashed while starting"
      actor.InitFailed(e) ->
        case e {
          process.Abnormal(e) -> "Failed to connect" <> e
          process.Killed -> "Process killed while connecting"
          process.Normal -> "Process start aborted (?)"
        }
      actor.InitTimeout -> "Establishing connection timed out"
    }
  })
}

/// Sends the given packet
pub fn send(connection: Connection, packet: outgoing.Packet) -> Nil {
  process.send(connection.subject, Send(packet))
}

/// Disconnects the connection cleanly
pub fn shutdown(connection: Connection) {
  process.send(connection.subject, ShutDown)
}

type Message {
  Send(outgoing.Packet)
  Received(#(BitArray, ChannelResult(List(incoming.Packet))))
  ProcessReceived(incoming.Packet)
  SendPing
  ShutDown
}

type State {
  State(
    self: Subject(Message),
    keep_alive_ms: Int,
    server_timeout_ms: Int,
    incoming: Subject(incoming.Packet),
    connection_state: ConnectionState,
  )
}

type ConnectionState {
  /// Connect packet has been sent, but we haven't gotten a connack
  ConnectingToServer(channel: EncodedChannel)
  Connected(
    channel: EncodedChannel,
    /// Timer for sending the next ping request
    ping_timer: process.Timer,
    /// Timer for shutting down the connection if a ping is not responded to in time
    shutdown_timer: Option(process.Timer),
  )
}

fn init(
  create_channel: fn() -> transport.ByteChannel,
  incoming: Subject(incoming.Packet),
  client_id: String,
  keep_alive_ms: Int,
  server_timeout_ms: Int,
) -> actor.InitResult(State, Message) {
  let self = process.new_subject()
  let channel = channel.as_encoded(create_channel())
  let connection_state = ConnectingToServer(channel)
  let state =
    State(self, keep_alive_ms, server_timeout_ms, incoming, connection_state)

  // TODO clean session, auth, will
  let connect_options =
    packet.ConnectOptions(
      clean_session: True,
      client_id: client_id,
      keep_alive_seconds: keep_alive_ms / 1000,
      auth: None,
      will: None,
    )
  case send_packet(state, outgoing.Connect(connect_options)) {
    Ok(state) -> actor.Ready(state, next_selector(channel, <<>>, state.self))
    Error(e) ->
      actor.Failed({
        "Error sending connect packet to server: " <> string.inspect(e)
      })
  }
}

fn run(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Received(#(new_channel_state, packets)) ->
      handle_receive(state, new_channel_state, packets)
    ProcessReceived(packet) -> process_packet(state, packet)
    Send(packet) -> send_from_session(state, packet)
    SendPing -> send_ping(state)
    ShutDown -> shut_down(state)
  }
}

fn shut_down(state: State) -> actor.Next(Message, State) {
  get_channel(state).shutdown()
  actor.Stop(process.Normal)
}

/// Sends a packet coming directly from the session
fn send_from_session(
  state: State,
  packet: outgoing.Packet,
) -> actor.Next(Message, State) {
  use state <- send_packet_or_stop(state, packet)
  actor.continue(state)
}

fn handle_receive(
  state: State,
  new_conn_state: BitArray,
  packets: ChannelResult(List(incoming.Packet)),
) -> actor.Next(Message, State) {
  case packets {
    Ok(packets) -> {
      // Schedule the packets to be processed,
      // to atomically update the actor state.
      list.each(packets, fn(packet) {
        process.send(state.self, ProcessReceived(packet))
      })

      // Continue receiving immediately 
      actor.with_selector(
        actor.continue(state),
        next_selector(get_channel(state), new_conn_state, state.self),
      )
    }
    Error(e) ->
      stop_abnormal(
        "Transport channel error while receiving: " <> string.inspect(e),
      )
  }
}

fn process_packet(
  state: State,
  packet: incoming.Packet,
) -> actor.Next(Message, State) {
  case packet {
    incoming.ConnAck(data) -> handle_connack(state, data)
    incoming.PingResp -> handle_pingresp(state)
    packet -> send_to_session(state, packet)
  }
}

fn send_to_session(
  state: State,
  packet: incoming.Packet,
) -> actor.Next(Message, State) {
  process.send(state.incoming, packet)
  actor.continue(state)
}

fn handle_connack(
  state: State,
  status: packet.ConnAckResult,
) -> actor.Next(Message, State) {
  case state.connection_state {
    ConnectingToServer(channel) -> {
      // TODO send connected update
      // process.send(reply_to, result.map_error(status, from_packet_connect_error))

      case status {
        Ok(_session_present) -> {
          let connection_state =
            Connected(channel, start_ping_timeout(state), None)
          actor.continue(State(..state, connection_state: connection_state))
        }
        Error(_) -> {
          // If a server sends a CONNACK packet containing a non-zero return code
          // it MUST then close the Network Connection
          // TODO: Send status to parent before shutting down
          shut_down(state)
        }
      }
    }
    Connected(..) -> stop_abnormal("Got ConnAck while already connected")
  }
}

fn send_ping(state: State) -> actor.Next(Message, State) {
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
            process.send_after(state.self, state.server_timeout_ms, ShutDown)
          actor.continue(
            State(
              ..state,
              connection_state: Connected(channel, ping, Some(disconnect)),
            ),
          )
        }
      }
    }
    ConnectingToServer(..) ->
      stop_abnormal("Trying to send ping while still connecting to server")
  }
}

fn handle_pingresp(state: State) -> actor.Next(Message, State) {
  case state.connection_state {
    Connected(channel, ping, Some(shutdown_timer)) -> {
      process.cancel_timer(shutdown_timer)
      actor.continue(
        State(..state, connection_state: Connected(channel, ping, None)),
      )
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
  if_success: fn(State) -> actor.Next(Message, State),
) -> actor.Next(Message, State) {
  case send_packet(state, packet) {
    Ok(state) -> if_success(state)
    Error(e) ->
      stop_abnormal(
        "Transport channel error "
        <> string.inspect(e)
        <> " while sending packet "
        <> string.inspect(packet),
      )
  }
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
fn send_packet(state: State, packet: outgoing.Packet) -> ChannelResult(State) {
  case state.connection_state {
    ConnectingToServer(channel) -> {
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
    ConnectingToServer(channel) -> channel
  }
}

fn stop_abnormal(description: String) -> actor.Next(Message, State) {
  actor.Stop(process.Abnormal(description))
}
