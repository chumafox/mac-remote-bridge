#!/usr/bin/env bash
set -e
extra_flags=""
if [ "$(uname -s)" = "Linux" ]; then
  extra_flags="-d"
fi
curl -fsSL https://raw.githubusercontent.com/chumafox/mac-remote-bridge/main/bridge.sh | bash -s -- -y --sudo ${extra_flags} "$@"
