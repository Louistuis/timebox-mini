#!/bin/sh
set -e
cd "$(dirname "$0")"
swiftc -swift-version 5 -O -framework IOBluetooth -framework Network -framework Foundation main.swift server.swift scan.swift game.swift -o tb
echo "built ./tb"
