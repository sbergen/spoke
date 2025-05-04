//// Conversions between `spoke/packet` and `spoke/mqtt` types.
//// These exist mostly so that high-level packages don't need to
//// expose any types from the `spoke_packet` package.

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

pub fn to_packet_qos(qos: mqtt.QoS) -> packet.QoS {
  case qos {
    mqtt.AtMostOnce -> packet.QoS0
    mqtt.AtLeastOnce -> packet.QoS1
    mqtt.ExactlyOnce -> packet.QoS2
  }
}

pub fn from_packet_qos(qos: packet.QoS) -> mqtt.QoS {
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
