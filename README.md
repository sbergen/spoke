# Spoke

This repository contains packages used to work with MQTT 3 in Gleam!
* [spoke_mqtt_js](./spoke_mqtt_js/) is a MQTT client for the JavaScript runtime.
* [spoke_mqtt_actor](./spoke_mqtt_actor/) is an actor-based MQTT client
  for the Erlang runtime.
* [spoke_tcp](./spoke_tcp/) provides TCP transport for spoke_mqtt_actor.
* [spoke_mqtt](./spoke_mqtt/) contains common types and functions for working
  with a MQTT client.
* [spoke_core](./spoke_core/) is the purely functional core used by both the
  clients (using [drift](https://github.com/sbergen/drift)).
* [spoke_packet](./spoke_packet/) is a library for encoding/decoding MQTT
  packets to/from binary.