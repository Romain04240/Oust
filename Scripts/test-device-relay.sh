#!/bin/bash
# Read-only native relay regressions. Reuse one tiny binary in the package cache.
set -euo pipefail
cd "$(dirname "$0")/.."
cache="Packages/OustKit/.build/device-relay-tests"
mkdir -p "$cache"
xcrun clang -std=c11 -Wall -Wextra \
    -I Packages/OustKit/Sources/OustDeviceRelay/include \
    Packages/OustKit/Tests/OustDeviceRelayNativeTests/WatchRelayTests.c \
    -framework CoreFoundation -o "$cache/watch-relay-regression-tests"
"$cache/watch-relay-regression-tests"
