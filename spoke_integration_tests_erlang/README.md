# spoke_integration_tests_erlang

Separate project for running integration tests on the Erlang target.
These can't be in the `spoke_mqtt_actor` package, as it would cause a
circular dependency (we depend on `spoke_tcp`).
Currently we only have a TCP transport channel,
but if more are added, we should run the same test suite with all channels.

Requires a locally running MQTT broker.
