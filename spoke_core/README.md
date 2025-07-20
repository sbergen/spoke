# spoke_core

[![Package Version](https://img.shields.io/hexpm/v/spoke_core)](https://hex.pm/packages/spoke_core)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/spoke_core/)

This package defines the purely functional core of an MQTT client, using
[drift](https://hexdocs.pm/drift).
For a fully functional MQTT client, you can use the following packages instead:
* [spoke_mqtt_actor](https://hexdocs.pm/spoke_mqtt_actor) wraps the 
  functionality in an OTP actor on the Erlang target, and 
  [spoke_tcp](https://hexdocs.pm/spoke_tcp) provides TCP-based transport on Erlang.
* [spoke_mqtt_js](https://hexdocs.pm/spoke_mqtt_js) provides a WebSocket-based
  wrapper for the JavaScript target.

As the package is primarily not intended for direct use,
the documentation is a bit sparse.
