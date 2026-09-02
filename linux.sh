#!/usr/bin/env bash
set -e
curl -fsSL https://raw.githubusercontent.com/chumafox/mac-remote-bridge/main/bridge.sh | bash -s -- -y --sudo "$@"
