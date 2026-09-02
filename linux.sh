#!/usr/bin/env bash
# Quick automated remote support bridge bootstrap for Linux
set -e

# Reconnect stdin to terminal if piped
if [ -r /dev/tty ]; then
  exec </dev/tty
fi

curl -fsSL https://raw.githubusercontent.com/chumafox/mac-remote-bridge/main/bridge.sh | bash -s -- -y --sudo "$@"
