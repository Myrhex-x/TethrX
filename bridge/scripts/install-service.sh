#!/usr/bin/env bash
# Kept for muscle memory. Installing the background service is now built into the
# bridge itself, so it also works from an `npm i -g tethrx-bridge` install rather
# than only from a clone of this repo — and it can inspect and remove the service
# as well as create it:
#
#   tethrx-bridge service install --host 0.0.0.0
#   tethrx-bridge service status | logs | restart | uninstall
#
# This wrapper forwards to that. It also supersedes the com.grokremote.bridge agent
# this script used to write; `service install` clears that one when it is holding
# the port.
set -euo pipefail

NODE="${NODE:-$(command -v node || true)}"
[ -x "$NODE" ] || NODE="$HOME/.local/node24/bin/node"
[ -x "$NODE" ] || { echo "node not found — set NODE=/path/to/node"; exit 1; }

SERVER="$(cd "$(dirname "$0")/.." && pwd)/src/server.mjs"
exec "$NODE" "$SERVER" service install --host "${GROK_REMOTE_HOST:-0.0.0.0}" "$@"
