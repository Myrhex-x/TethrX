# TethrX

*A client for Grok Build — independent, not affiliated with xAI. (Internal codename: grok-remote.)*


Drive **Grok Build** running on your computer from your **iPhone** — like [Hermex](https://hermexapp.com/) is for Hermes, but for xAI's Grok Build CLI.

Your phone is only a control plane. Grok, its tools, and your code stay on your machine; the phone sends prompts, watches Grok work **tool-by-tool**, and **approves or rejects** each action.

```
┌────────────┐   HTTP + SSE    ┌─────────────────────┐   JSON-RPC (ACP)   ┌───────────┐
│  iOS app   │  ────────────▶  │   bridge daemon     │  ───────────────▶  │  grok     │
│ (SwiftUI)  │  ◀────────────  │  (Node, on your Mac)│  ◀───────────────  │  agent    │
└────────────┘  token + push   └─────────────────────┘  tools/plans/asks  └───────────┘
```

- **`bridge/`** — a zero-dependency Node daemon that wraps your installed `grok` and exposes it over an authenticated HTTP + SSE API. Two transports: **ACP** (default — streams tool calls, plans, and live approve/reject) and **headless** (simple text+thought).
- **`ios/`** — a native SwiftUI app (xAI design language): pairing, session list, and a live console with tool activity and approval cards.

Everything below is **built and tested** against a real `grok` install.

---

## Quickstart

### 1. Run the bridge (on the machine where Grok Build is installed)

Needs **Node.js 20+** and **Grok Build** installed + signed in.

```bash
npx tethrx-bridge
```

It prints a **pairing token** and its address. Want it always-on?

```bash
npm i -g tethrx-bridge && tethrx-bridge
# or, from a clone of this repo, the launchd service:
bash bridge/scripts/install-service.sh
```

**Easiest pairing:** open **`http://localhost:4180/pair`** on the computer running the bridge. It shows a scannable QR code (one for Wi-Fi, one for Tailscale) plus the token to copy. That page is **loopback-only** — the token never leaves the machine.

### 2. Run the app

```bash
open ios/GrokRemote.xcodeproj      # Xcode 26.3+ / 27
```

Pick a simulator (or set your Team + a device), Run. Tap **Scan to pair** and point at a code on `localhost:4180/pair` — or enter the **bridge address** + **pairing token** by hand — then **＋** to start a session.

---

## Approvals (the headline feature)

With the ACP transport, when Grok wants to run a shell command or edit a file, the phone shows an **approval card** with the exact command and Grok's own options ("Yes, proceed" / "No, and tell Grok…"). Nothing runs until you tap.

- **On by default.** The bridge runs Grok under a **redirected HOME** so per-tool prompting is enabled *without editing your global `~/.grok/config.toml`* (it symlinks your real files and supplies its own `config.toml`).
- Set `GROK_REMOTE_ASK=0` to inherit your global grok permission config instead (e.g. if you run `always-approve` and want the phone to match).
- You still see everything either way: thoughts, `tool_call`s with their commands, live `tool_update` status + exit codes, and plans.

---

## Connectivity: using it away from your desk

The phone must reach the bridge. Options, easiest first:

| Setup | How | Notes |
| --- | --- | --- |
| **Same Wi-Fi** | `GROK_REMOTE_HOST=0.0.0.0`, use your Mac's LAN IP | Home/office only |
| **Tailscale** (recommended) | Install on Mac + phone (same tailnet). Bind `0.0.0.0`, use the Mac's `100.x.y.z` address in the app | Works over cellular, encrypted end-to-end, no port-forwarding |
| **TLS on LAN** | `bash bridge/scripts/gen-cert.sh` then set `GROK_REMOTE_TLS_CERT` / `GROK_REMOTE_TLS_KEY` | Serves HTTPS; the app allows the self-signed cert on local networks |

Never expose the bridge directly to the public internet — it can run code on your machine. Tailscale gives you remote access without doing that.

---

## Push notifications (optional)

So you're alerted when Grok **needs approval** or **finishes** while the app is backgrounded:

```bash
GROK_REMOTE_NTFY="https://ntfy.sh/your-secret-topic" node bridge/src/server.mjs
```

Subscribe to that topic in the [ntfy](https://ntfy.sh) app on your phone. The bridge only pushes when no client is actively watching that session (so you're not double-notified).

---

## Configuration (env)

| Var | Default | Meaning |
| --- | --- | --- |
| `GROK_REMOTE_HOST` | `127.0.0.1` | Bind address (`0.0.0.0` for LAN/Tailscale) |
| `GROK_REMOTE_PORT` | `4180` | Port |
| `GROK_REMOTE_TRANSPORT` | `acp` | `acp` (rich + approvals) or `headless` |
| `GROK_REMOTE_ASK` | `1` | ACP per-tool prompts (`0` = inherit global grok config) |
| `GROK_REMOTE_NTFY` | — | ntfy topic URL for push |
| `GROK_REMOTE_TLS_CERT` / `_KEY` | — | PEM paths to serve HTTPS |
| `GROK_REMOTE_CWD` | `~` | Default working directory for new sessions |
| `GROK_BIN` | auto | Path to the `grok` binary |

State (pairing token, session registry, redirected grok-home) lives in `~/.grok-remote/`.

---

## Security

- **Token auth** on every request (minted on first run, stored `0600`). The iOS app keeps it in the **Keychain**.
- Approvals mean Grok can't run a command or edit a file without your explicit tap (with `GROK_REMOTE_ASK=1`).
- Use **Tailscale or TLS** whenever the bridge is reachable beyond loopback. Nothing talks to a third party except optional ntfy pushes you configure.

---

## Roadmap

- [x] **ACP transport** — tool calls, plans, live approve/reject on the phone
- [x] **Plan mode** — Grok drafts a plan; review + approve on the phone before it builds
- [x] **Context resume across restarts** — ACP `session/load` restores conversation; event history persisted + replayed so past sessions open and follow
- [x] **Lock-screen approvals** — ntfy action buttons resolve a permission without opening the app
- [x] Delete / rename sessions, idle ACP-process cleanup
- [x] Persistence, launchd service, TLS, ntfy push, Keychain, reasoning-effort picker, app icon
- [ ] **Relay** — for cellular without Tailscale (`grok agent headless --grok-ws-url wss://…` exists)
- [ ] **Image attachments** — *blocked:* grok 0.2.103 ACP reports `promptCapabilities.image=false`. Text/file context (`embeddedContext`) is supported; images await grok support.

---

## Layout

```
grok-remote/
├── bridge/
│   ├── src/{server,acp,grok,sessions,config}.mjs   # daemon (ACP + headless)
│   ├── scripts/{install-service,gen-cert}.sh        # launchd + TLS
│   ├── public/index.html                            # web test client
│   └── test/*.mjs                                    # smoke + ACP + verify tests
├── ios/
│   ├── GrokRemote.xcodeproj
│   ├── GrokRemote/                                   # SwiftUI sources (synced group)
│   └── tools/probe.swift                             # live test of the app's networking
└── sandbox/                                          # scratch dir for demo Grok sessions
```
