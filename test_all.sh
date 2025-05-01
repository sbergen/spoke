#!/usr/bin/env bash
cd "$(dirname "$0")"

set -e

for dirname in "spoke_packet" "spoke_core" "spoke_tcp" "spoke"; do
    pushd "$dirname" > /dev/null
    echo "======================================="
    echo " Testing $dirname"
    echo "======================================="
    gleam test
    popd > /dev/null
done
