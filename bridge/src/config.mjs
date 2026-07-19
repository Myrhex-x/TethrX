// Configuration + pairing-token management for the Grok Remote bridge.
//
// The bridge stores its state under ~/.grok-remote/ (NOT the project dir), so the
// pairing token never lands in source control. On first run we mint a token; the
// phone must present it as `Authorization: Bearer <token>` on every request.

import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

const STATE_DIR = join(homedir(), ".grok-remote");
const CONFIG_PATH = join(STATE_DIR, "config.json");

// Resolve the grok binary. Prefer an explicit override, then the standard install
// location, then bare `grok` on PATH (spawn will surface a clear error if missing).
function resolveGrokBin() {
  if (process.env.GROK_BIN) return process.env.GROK_BIN;
  const standard = join(homedir(), ".grok", "bin", "grok");
  if (existsSync(standard)) return standard;
  return "grok";
}

const DEFAULTS = {
  // 127.0.0.1 keeps the bridge private to this machine. Set to "0.0.0.0" (or use a
  // Tailscale/VPN address) to let a phone on your network reach it. See README.
  host: process.env.GROK_REMOTE_HOST || "127.0.0.1",
  port: Number(process.env.GROK_REMOTE_PORT || 4180),
  // Where new Grok sessions operate by default. Deliberately NOT the current repo —
  // each session can override this per-request.
  defaultCwd: process.env.GROK_REMOTE_CWD || homedir(),
  // Empty => let Grok pick its own default model (portable across installs). Set
  // GROK_REMOTE_MODEL, or pass `model` per session, to pin a specific one.
  defaultModel: process.env.GROK_REMOTE_MODEL || "",
  // Permission posture for the HEADLESS transport (can't prompt): "acceptEdits" lets
  // Grok edit files without asking; shell still follows allow/deny.
  defaultPermissionMode: process.env.GROK_REMOTE_PERMISSION_MODE || "acceptEdits",

  // Transport for new sessions: "acp" (rich — tool calls, plans, live approve/reject)
  // or "headless" (simple text+thought stream). ACP is the better default.
  transport: process.env.GROK_REMOTE_TRANSPORT || "acp",

  // With ACP, run Grok under a redirected HOME so it prompts per tool (phone approves).
  // Set GROK_REMOTE_ASK=0 to inherit your global grok permission config instead.
  askPermission: (process.env.GROK_REMOTE_ASK ?? "1") !== "0",

  // Optional ntfy topic URL (e.g. https://ntfy.sh/your-secret-topic) for push alerts
  // when the app isn't watching a session — approval-needed and turn-complete.
  ntfy: process.env.GROK_REMOTE_NTFY || "",

  // Publicly-reachable base URL of THIS bridge (e.g. https://100.x.y.z:4180 over
  // Tailscale). Enables Approve/Reject buttons on the push so you can resolve from
  // the lock screen. Without it, pushes are informational only.
  publicUrl: process.env.GROK_REMOTE_PUBLIC_URL || "",

  // Optional TLS. Set both to a PEM cert/key to serve HTTPS (recommended when binding
  // beyond loopback). See scripts/gen-cert.sh.
  tlsCert: process.env.GROK_REMOTE_TLS_CERT || "",
  tlsKey: process.env.GROK_REMOTE_TLS_KEY || "",
};

function load() {
  mkdirSync(STATE_DIR, { recursive: true });

  let stored = {};
  if (existsSync(CONFIG_PATH)) {
    try {
      stored = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
    } catch {
      // Corrupt config: fall through and rewrite with a fresh token.
      stored = {};
    }
  }

  // Mint a pairing token on first run and persist it (0600).
  if (!stored.token) {
    stored.token = randomBytes(24).toString("base64url");
    writeFileSync(CONFIG_PATH, JSON.stringify(stored, null, 2), { mode: 0o600 });
  }

  return {
    stateDir: STATE_DIR,
    configPath: CONFIG_PATH,
    token: stored.token,
    grokBin: resolveGrokBin(),
    name: "TethrX",
    ...DEFAULTS,
    // Allow the stored file to override any default (e.g. a pinned cwd).
    ...pickOverrides(stored),
  };
}

function pickOverrides(stored) {
  const out = {};
  for (const k of ["host", "port", "defaultCwd", "defaultModel", "defaultPermissionMode", "transport"]) {
    if (stored[k] !== undefined) out[k] = stored[k];
  }
  return out;
}

export const config = load();
