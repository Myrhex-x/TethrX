#!/usr/bin/env bash
# Install the bridge as a launchd user agent so it starts at login and restarts if
# it crashes. Binds 0.0.0.0 by default so a phone on your network can reach it.
#
#   bash scripts/install-service.sh
#   # env overrides: NODE=/path/to/node GROK_REMOTE_HOST=127.0.0.1 GROK_REMOTE_NTFY=...
set -euo pipefail

NODE="${NODE:-$HOME/.local/node24/bin/node}"
[ -x "$NODE" ] || NODE="$(command -v node || true)"
[ -x "$NODE" ] || { echo "node not found — set NODE=/path/to/node"; exit 1; }

SERVER="$(cd "$(dirname "$0")/.." && pwd)/src/server.mjs"
LABEL="com.grokremote.bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/.grok-remote"
mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$SERVER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>GROK_REMOTE_HOST</key><string>${GROK_REMOTE_HOST:-0.0.0.0}</string>
    <key>GROK_REMOTE_NTFY</key><string>${GROK_REMOTE_NTFY:-}</string>
    <key>GROK_REMOTE_TLS_CERT</key><string>${GROK_REMOTE_TLS_CERT:-}</string>
    <key>GROK_REMOTE_TLS_KEY</key><string>${GROK_REMOTE_TLS_KEY:-}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOGDIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/bridge.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed + started: $LABEL"
echo "  logs:  $LOGDIR/bridge.log"
echo "  token: grep it from the log (first run) — printed once at startup"
echo "  stop:  launchctl unload $PLIST"
