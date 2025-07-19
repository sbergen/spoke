# spoke_mqtt

[![Package Version](https://img.shields.io/hexpm/v/spoke_mqtt)](https://hex.pm/packages/spoke_mqtt)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/spoke_mqtt/)


Contains all the data types needed to work with spoke MQTT libraries,
without having to interact with the lower level packet types.
This also makes it possible to write common code for different targets,
and reduces code duplication.

See the following packages for a client implementation: 
* [spoke_mqtt_actor](https://hexdocs.pm/spoke_mqtt_actor) and 
  [spoke_tcp](https://hexdocs.pm/spoke_tcp) for the Erlang target.
* [spoke_mqtt_js](https://hexdocs.pm/spoke_mqtt_js) for the JavaScript target.

For encoding and decoding packets, see [spoke_packet](https://hexdocs.pm/spoke_packet).