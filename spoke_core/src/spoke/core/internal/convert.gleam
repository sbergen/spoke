//// Conversions that exist only/mostly because we separate packet types from public types.

import gleam/option.{type Option}
import spoke/mqtt
import spoke/packet

pub fn to_connection_state(result: packet.ConnAckResult) -> mqtt.ConnectionState {
  case result {
    Ok(session_present) ->
      mqtt.ConnectAccepted(case session_present {
        packet.SessionPresent -> mqtt.SessionPresent
        packet.SessionNotPresent -> mqtt.SessionNotPresent
      })
    Error(error) -> mqtt.ConnectRejected(from_packet_connect_error(error))
  }
}

pub fn to_auth_options(
  options: Option(mqtt.AuthDetails),
) -> Option(packet.AuthOptions) {
  use options <- option.map(options)
  packet.AuthOptions(options.username, options.password)
}

pub fn to_will(data: mqtt.PublishData) -> #(packet.MessageData, packet.QoS) {
  let msg_data = packet.MessageData(data.topic, data.payload, data.retain)
  #(msg_data, to_packet_qos(data.qos))
}

fn to_packet_qos(qos: mqtt.QoS) -> packet.QoS {
  case qos {
    mqtt.AtMostOnce -> packet.QoS0
    mqtt.AtLeastOnce -> packet.QoS1
    mqtt.ExactlyOnce -> packet.QoS2
  }
}

fn from_packet_qos(qos: packet.QoS) -> mqtt.QoS {
  case qos {
    packet.QoS0 -> mqtt.AtMostOnce
    packet.QoS1 -> mqtt.AtLeastOnce
    packet.QoS2 -> mqtt.ExactlyOnce
  }
}

fn from_packet_connect_error(error: packet.ConnectError) -> mqtt.ConnectError {
  case error {
    packet.BadUsernameOrPassword -> mqtt.BadUsernameOrPassword
    packet.IdentifierRefused -> mqtt.IdentifierRefused
    packet.NotAuthorized -> mqtt.NotAuthorized
    packet.ServerUnavailable -> mqtt.ServerUnavailable
    packet.UnacceptableProtocolVersion -> mqtt.UnacceptableProtocolVersion
  }
}
