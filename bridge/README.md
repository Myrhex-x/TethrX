# tethrx-bridge

The local bridge for **[TethrX](https://github.com/Myrhex-x/TethrX)** — run **Grok Build** (xAI's terminal coding agent) from your phone.

The bridge runs on your computer and exposes your Grok Build install to the TethrX iOS app over HTTP + SSE: streamed thoughts, tool calls, and per-tool **approvals** you tap from your phone.

## Requirements

- **Node.js 20+**
- **Grok Build** installed and signed in (`grok --version` should work)

## Run

```bash
npx tethrx-bridge
```

It prints a **bridge address** and a **pairing token**. On the same computer, open **http://localhost:4180/pair** to get a scannable QR code, then in the TethrX app tap **Scan to pair**.

Prefer it always-on? Install it globally and run the binary (or wrap it in a launchd/systemd service):

```bash
npm i -g tethrx-bridge
tethrx-bridge
```

## Reaching it from your phone

- **Same Wi-Fi:** use the LAN address it prints.
- **Anywhere (cellular):** put your computer and phone on [Tailscale](https://tailscale.com) and use the `100.x` address. Never expose the bridge directly to the public internet — it can run commands on your machine.

## Config

Environment variables (all optional):

| Var | Default | Notes |
| --- | --- | --- |
| `GROK_REMOTE_HOST` | `127.0.0.1` | `0.0.0.0` to allow LAN/Tailscale |
| `GROK_REMOTE_PORT` | `4180` | Port |
| `GROK_BIN` | auto | Path to the `grok` binary |
| `GROK_REMOTE_ASK` | `1` | Per-tool approval prompts (`0` inherits your global grok config) |
| `GROK_REMOTE_TLS_CERT` / `_KEY` | — | Serve HTTPS |

State (pairing token, session registry) lives in `~/.grok-remote/` — never in this package.

## License

Apache-2.0
