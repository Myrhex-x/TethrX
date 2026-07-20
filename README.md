# TethrX

*A client for Grok Build — independent, not affiliated with xAI.*


Drive **Grok Build** running on your computer from your **iPhone**

Your phone is only a control plane. Grok, its tools, and your code stay on your machine; the phone sends prompts, watches Grok work **tool-by-tool**, and **approves or rejects** each action.

**Public TestFlight:** https://testflight.apple.com/join/nR19zett — you still run the bridge yourself (below).

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

## What the app does

- **Live console** — Grok's reasoning, tool calls, **command output**, and file diffs as they happen, with code rendered as real blocks you can scroll and copy.
- **Approvals** — nothing runs until you tap. Also answerable straight from the notification.
- **Plan mode** — read the plan before Grok builds it.
- **Review the work** — changed files, per-file diffs, and **commit or discard** from the phone.
- **Slash commands** — grok's own (`/compact`, `/context`, …) plus any skills you have installed.
- **Voice dictation**, **queued follow-ups**, and reusable prompt snippets.
- **Sessions** — search, folders, and several paired computers you can switch between.
- **Siri** — start a task or ask what Grok is doing without opening the app.
- **Home-screen widget** and a **Live Activity** on the lock screen / Dynamic Island.
- **Usage** — context window, tokens, and cost per session.
- **Face ID lock**, since the bridge can run commands on your machine.
- Your computer is kept **awake** for as long as a task is running.

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

So you're alerted when Grok **needs approval** or **finishes** while the app is backgrounded. The bridge only pushes when no client is actively watching that session, so you're never double-notified.

**Native push (APNs).** Because the bridge is *your* server, it pushes with *your* APNs key — nothing routes through a third party. Create an APNs auth key (Keys → Apple Push Notifications service) in your Apple developer account, then add to `~/.grok-remote/config.json`:

```json
{
  "apns": {
    "keyPath": "/Users/you/.grok-remote/AuthKey_XXXXXXXXXX.p8",
    "keyId": "XXXXXXXXXX",
    "teamId": "YOURTEAMID"
  }
}
```

Scope the key to **Sandbox & Production** — a TestFlight build uses the production environment. Then enable notifications in the app's Settings. Approvals arrive with **Approve / Reject** buttons on the notification itself.

> This requires an Apple developer account, so it's genuinely optional. Without it everything else works; you just won't get alerts while the app is closed.

**ntfy (no developer account needed).**

```bash
GROK_REMOTE_NTFY="https://ntfy.sh/your-secret-topic" npx tethrx-bridge
```

Subscribe to that topic in the [ntfy](https://ntfy.sh) app.

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
- [x] **Context resume across restarts** — ACP `session/load` restores conversation; event history persisted + replayed
- [x] **Lock-screen approvals** — native APNs (and ntfy) action buttons resolve a permission without opening the app
- [x] **Command output + code blocks** — see *why* something failed, not just that it did
- [x] **Git review** — changed files, per-file diffs, commit or discard from the phone
- [x] **Slash commands** — grok's built-ins and your installed skills
- [x] **Voice dictation, queued follow-ups, prompt snippets**
- [x] **Sessions** — search, folders, several paired computers
- [x] **Siri (App Intents)**, home-screen widget, Live Activity
- [x] **Sleep prevention** — the machine stays awake while a turn runs
- [x] Persistence, launchd service, TLS, Keychain, reasoning-effort picker, Face ID lock
- [ ] **Pinned HTTPS** — self-signed cert with its fingerprint in the pairing QR, so cleartext is never needed
- [ ] **Relay** — for cellular without Tailscale (`grok agent headless --grok-ws-url wss://…` exists)
- [ ] **Image attachments** — *blocked:* grok's ACP reports `promptCapabilities.image=false`. Text/file context (`embeddedContext`) works; images await grok support.

---

## Layout

```
grok-remote/
├── bridge/
│   ├── src/{server,acp,grok,sessions,config}.mjs   # daemon (ACP + headless)
│   ├── src/{apns,awake,git}.mjs                    # push, sleep prevention, git review
│   ├── scripts/{install-service,gen-cert}.sh       # launchd + TLS
│   ├── public/index.html                           # web test client
│   └── test/*.mjs                                  # smoke + ACP + verify tests
├── ios/
│   ├── GrokRemote.xcodeproj
│   ├── GrokRemote/                                 # SwiftUI sources (synced group)
│   ├── TethrXWidget/                               # Live Activity + home-screen widget
│   └── tools/probe.swift                           # live test of the app's networking
└── sandbox/                                        # scratch dir for demo Grok sessions
```

---

## Licence

[Apache License 2.0](LICENSE). TethrX is an independent client for Grok Build and is not affiliated with, endorsed by, or sponsored by xAI.
