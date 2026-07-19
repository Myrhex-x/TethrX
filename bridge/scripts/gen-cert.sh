#!/usr/bin/env bash
# Generate a self-signed TLS cert/key for the bridge, valid for localhost + this
# Mac's LAN IP. Use when binding beyond loopback on an untrusted network.
#
#   bash scripts/gen-cert.sh
#   GROK_REMOTE_TLS_CERT=~/.grok-remote/tls-cert.pem \
#   GROK_REMOTE_TLS_KEY=~/.grok-remote/tls-key.pem node src/server.mjs
set -euo pipefail

DIR="${1:-$HOME/.grok-remote}"
mkdir -p "$DIR"
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"

openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout "$DIR/tls-key.pem" -out "$DIR/tls-cert.pem" \
  -subj "/CN=grok-remote" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${IP}"

chmod 600 "$DIR/tls-key.pem"
echo
echo "Wrote:"
echo "  $DIR/tls-cert.pem"
echo "  $DIR/tls-key.pem   (LAN IP: ${IP})"
echo
echo "Start the bridge over HTTPS:"
echo "  GROK_REMOTE_HOST=0.0.0.0 \\"
echo "  GROK_REMOTE_TLS_CERT=$DIR/tls-cert.pem \\"
echo "  GROK_REMOTE_TLS_KEY=$DIR/tls-key.pem \\"
echo "  node src/server.mjs"
echo
echo "The cert is self-signed; the iOS app allows it on your local network."
