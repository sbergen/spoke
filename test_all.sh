#!/usr/bin/env bash
cd "$(dirname "$0")"

set -e

for dirname in "spoke_packet" "spoke_mqtt" "spoke_core" "spoke_mqtt_js" "spoke_mqtt_actor" "spoke_tcp" "spoke_integration_tests_erlang"; do
    pushd "$dirname" > /dev/null
    echo "======================================="
    echo " Testing $dirname"
    echo "======================================="
    gleam test
    popd > /dev/null
done
