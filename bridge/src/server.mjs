#!/usr/bin/env node
// Grok Remote bridge — HTTP + SSE server.
//
// Exposes a running, authenticated Grok Build install to a phone (or any) client:
//   GET  /api/health                     -> liveness + grok version (no auth)
//   GET  /api/sessions                   -> list sessions
//   POST /api/sessions                   -> { cwd?, model?, title? } create a session
//   GET  /api/sessions/:id               -> session detail
//   POST /api/sessions/:id/messages      -> { text, permissionMode?, alwaysApprove?, allow?, deny? }
//   POST /api/sessions/:id/cancel        -> abort the running turn
//   GET  /api/sessions/:id/stream        -> SSE stream of normalized Grok events
//   GET  /                               -> bundled web test client
//
// Auth: every /api route (except health) requires `Authorization: Bearer <token>`.
// SSE also accepts `?token=` because browser EventSource can't set headers (native
// iOS URLSession can, and should use the header).

import { createServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { readFile, readdir, stat, writeFile } from "node:fs/promises";
import { readFileSync, mkdirSync, readdirSync, statSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize as normPath, resolve as resolvePath, sep } from "node:path";
import { timingSafeEqual, randomBytes } from "node:crypto";
import { networkInterfaces, hostname, homedir } from "node:os";

import { config } from "./config.mjs";
import { SessionStore } from "./sessions.mjs";
import { runHeadlessTurn, grokVersion } from "./grok.mjs";
import { ensureAskGrokHome, AcpSession } from "./acp.mjs";
import { loadApns } from "./apns.mjs";
import { ScheduleStore, startScheduler } from "./schedules.mjs";
import * as awake from "./awake.mjs";
import * as git from "./git.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "..", "public");
const store = new SessionStore(join(config.stateDir, "sessions.json"));
const apns = loadApns(config);   // native push (disabled unless an APNs key is configured)
const schedules = new ScheduleStore(join(config.stateDir, "schedules.json"));

// Attached images land here; grok views them with its own (vision-capable) read
// tool. ACP declares image content blocks unsupported (promptCapabilities.image:
// false), so a file on disk + its path in the prompt is the working transport.
const UPLOAD_DIR = join(config.stateDir, "uploads");
try {
  mkdirSync(UPLOAD_DIR, { recursive: true });
  const cutoff = Date.now() - 7 * 24 * 3600_000;   // sweep uploads older than a week
  for (const f of readdirSync(UPLOAD_DIR)) {
    try { if (statSync(join(UPLOAD_DIR, f)).mtimeMs < cutoff) rmSync(join(UPLOAD_DIR, f), { force: true }); } catch { /* ignore */ }
  }
} catch { /* uploads become unavailable, not fatal */ }

// Single-use, decision-bound tokens for lock-screen approval links, so the full
// pairing token is never embedded in an ntfy notification.
const approvalTokens = new Map(); // token -> { sessionId, requestId, optionId, exp }
function mintApprovalToken(sessionId, requestId, optionId) {
  const now = Date.now();
  for (const [k, v] of approvalTokens) if (v.exp < now) approvalTokens.delete(k); // sweep stale
  const t = randomBytes(18).toString("base64url");
  approvalTokens.set(t, { sessionId, requestId, optionId, exp: now + 15 * 60 * 1000 });
  return t;
}

// What a push notification calls the session. Unnamed sessions are titled
// "New session", which is useless on a lock screen with several of them — fall
// back to the working directory's folder name, like the app's own list does.
function displayTitle(session) {
  const t = String(session.title || "").trim();
  if (t && t !== "New session") return t;
  if (session.cwd) return String(session.cwd).split("/").filter(Boolean).pop() || "session";
  return "session";
}

// For ACP + ask-mode, run Grok under a redirected HOME that enables per-tool prompts
// without touching the user's global ~/.grok/config.toml. Built once at startup.
const grokHome = config.transport === "acp" && config.askPermission
  ? ensureAskGrokHome(config.stateDir)
  : null;

// ---- helpers ---------------------------------------------------------------

// Reachable IPv4 addresses for the pairing-page QR codes. Tailscale (100.x) first,
// since that's the "works from anywhere" one.
function reachableAddresses() {
  const out = [];
  const ifaces = networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const ni of ifaces[name] || []) {
      if (ni.family !== "IPv4" || ni.internal) continue;
      out.push({ ip: ni.address, kind: ni.address.startsWith("100.") ? "Tailscale" : "Wi-Fi / LAN" });
    }
  }
  return out.sort((a, b) => (b.kind === "Tailscale") - (a.kind === "Tailscale"));
}

// True only for requests from THIS machine — the pairing page reveals the token,
// so it must never be served to the LAN/Tailscale.
function isLoopback(req) {
  const a = req.socket?.remoteAddress || "";
  return a === "127.0.0.1" || a === "::1" || a === "::ffff:127.0.0.1";
}

// The local pairing page: shows the token + a scannable QR per address. Rendered
// client-side by the vendored qrcode.js. Payload is a tethrx://pair deep link.
function pairPageHTML() {
  const addrs = reachableAddresses();
  const port = config.port;
  // Bound to loopback => the QR addresses below are NOT reachable from a phone.
  // Say so plainly instead of handing out codes that can only fail.
  const loopbackOnly = ["127.0.0.1", "::1", "localhost"].includes(String(config.host));
  const data = JSON.stringify({ token: config.token, port, addrs, loopbackOnly });
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pair TethrX</title><script src="/qrcode.js"></script>
<style>
:root{color-scheme:dark}
body{margin:0;background:#0a0a0a;color:#fff;font-family:-apple-system,system-ui,sans-serif;padding:32px 20px;-webkit-font-smoothing:antialiased}
.wrap{max-width:560px;margin:0 auto}
.mark{font-family:ui-monospace,Menlo,monospace;font-weight:700;font-size:19px;border:1px solid rgba(255,255,255,.22);border-radius:10px;width:40px;height:40px;display:flex;align-items:center;justify-content:center}
h1{font-size:26px;letter-spacing:-.5px;margin:14px 0 6px}
p.sub{color:rgba(255,255,255,.55);margin:0 0 26px;line-height:1.5}
.card{border:1px solid rgba(255,255,255,.13);border-radius:16px;padding:20px;margin:14px 0;background:rgba(255,255,255,.02)}
.card.warn{border-color:rgba(255,255,255,.35);background:rgba(255,255,255,.05)}
.eyebrow{font-family:ui-monospace,Menlo,monospace;font-size:11px;letter-spacing:1.5px;color:rgba(255,255,255,.55);text-transform:uppercase}
.qr{background:#fff;border-radius:12px;padding:12px;width:220px;margin:12px 0}
.qr svg{display:block;width:100%;height:auto}
.addr{font-family:ui-monospace,Menlo,monospace;font-size:14px}
.dim{color:rgba(255,255,255,.5)}
.tokrow{display:flex;gap:10px;align-items:center;margin-top:8px}
code{font-family:ui-monospace,Menlo,monospace;background:rgba(255,255,255,.06);padding:8px 10px;border-radius:8px;font-size:13px;word-break:break-all;flex:1}
button{font:inherit;font-size:13px;color:#000;background:#fff;border:0;border-radius:8px;padding:8px 14px;cursor:pointer;font-weight:600}
.note{color:rgba(255,255,255,.32);font-size:12px;font-family:ui-monospace,Menlo,monospace;margin-top:22px;line-height:1.6}
</style></head><body><div class="wrap">
<div class="mark">T</div>
<h1>Pair your phone</h1>
<p class="sub">In TethrX, tap <b>Scan to pair</b> and point your phone at a code below. Wi-Fi works at home; Tailscale works from anywhere.</p>
<div id="cards"></div>
<div class="card">
  <div class="eyebrow">Pairing token</div>
  <div class="tokrow"><code id="tok"></code><button onclick="navigator.clipboard.writeText(D.token)">Copy</button></div>
  <p class="dim" style="margin:10px 0 0;font-size:12px">Or type it by hand with the address above.</p>
</div>
<p class="note">this page is only reachable from this computer · the token grants full access to run commands here — don't share a screenshot of it</p>
</div>
<script>
var D = ${data};
document.getElementById('tok').textContent = D.token;
var host = document.getElementById('cards');
if (D.loopbackOnly) {
  host.innerHTML =
    '<div class="card warn">' +
    '<div class="eyebrow">One more step</div>' +
    '<p style="margin:10px 0 4px;line-height:1.5">This bridge is only listening on this computer, so your phone can\'t reach it yet. Stop it with Ctrl+C and start it again like this:</p>' +
    '<div class="tokrow"><code>GROK_REMOTE_HOST=0.0.0.0 npx tethrx-bridge</code>' +
    '<button onclick="navigator.clipboard.writeText(\'GROK_REMOTE_HOST=0.0.0.0 npx tethrx-bridge\')">Copy</button></div>' +
    '<p class="dim" style="margin:12px 0 0;font-size:12px">Then reload this page and the QR codes will appear. Only do this on a network you trust: the token is what protects the bridge.</p>' +
    '</div>';
} else if (!D.addrs.length) {
  host.innerHTML = '<div class="card dim">No network address found. Connect to Wi-Fi or start Tailscale, then reload.</div>';
}
if (!D.loopbackOnly) D.addrs.forEach(function(a){
  var addr = a.ip + ':' + D.port;
  var payload = 'tethrx://pair?addr=' + encodeURIComponent(addr) + '&token=' + encodeURIComponent(D.token);
  var card = document.createElement('div'); card.className = 'card';
  card.innerHTML = '<div class="eyebrow">'+a.kind+'</div><div class="qr" id="q'+a.ip.replace(/\\./g,'_')+'"></div><div class="addr">'+addr+'</div>';
  host.appendChild(card);
  var qr = qrcode(0, 'M'); qr.addData(payload); qr.make();
  document.getElementById('q'+a.ip.replace(/\\./g,'_')).innerHTML = qr.createSvgTag({ scalable: true, margin: 0 });
});
</script>
</body></html>`;
}

// NOTE: deliberately no `access-control-allow-origin`. This used to send "*" on every
// response, including /pair — which embeds the pairing token. That let ANY web page the
// user happened to be visiting do fetch("http://127.0.0.1:4180/pair"), read the token
// out of the response, and then drive the API, i.e. run arbitrary commands on the
// machine. Nothing legitimate needs CORS here: the iOS app uses URLSession (which
// ignores CORS) and the bundled web client is same-origin.
function send(res, status, body, headers = {}) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "content-type": typeof body === "string" ? "text/plain; charset=utf-8" : "application/json",
    "x-content-type-options": "nosniff",
    ...headers,
  });
  res.end(payload);
}

// A page fetched cross-site, or reached through a rebound DNS name, must never be able
// to read the pairing page. CORS alone can't stop DNS rebinding (the attacker's origin
// becomes same-origin), so the Host header is checked too.
function isDirectLocalRequest(req) {
  if (req.headers.origin) return false;                       // cross-origin fetch
  const site = String(req.headers["sec-fetch-site"] || "");
  if (site && site !== "none" && site !== "same-origin") return false;
  const host = String(req.headers.host || "").toLowerCase().replace(/:\d+$/, "");
  return ["localhost", "127.0.0.1", "::1", "[::1]"].includes(host);
}

function tokenOk(provided) {
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(config.token);
  return a.length === b.length && timingSafeEqual(a, b);
}

function authed(req, url) {
  const header = req.headers.authorization || "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7) : null;
  const qp = url.searchParams.get("token");
  return tokenOk(bearer) || tokenOk(qp);
}

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function serveStatic(res, urlPath) {
  const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
  const full = normPath(join(PUBLIC_DIR, rel));
  if (full !== PUBLIC_DIR && !full.startsWith(PUBLIC_DIR + sep)) return send(res, 403, "forbidden");
  try {
    const data = await readFile(full);
    const type = full.endsWith(".html") ? "text/html; charset=utf-8"
      : full.endsWith(".js") ? "text/javascript"
      : full.endsWith(".css") ? "text/css"
      : "application/octet-stream";
    res.writeHead(200, { "content-type": type });
    res.end(data);
  } catch {
    send(res, 404, "not found");
  }
}

// ---- turn execution --------------------------------------------------------

// Push a notification via ntfy, but only when nobody is actively watching this
// session (so you're alerted precisely when the app is backgrounded).
async function pushNotify(session, { title, message, priority = "default", tags, actions, category, requestId, allowOptionId, rejectOptionId }) {
  if (session.subscriberCount > 0) return;   // someone's watching live — no need to alert
  // Native push straight to the phone (when an APNs key is configured).
  apns.send({
    title, body: message, sessionId: session.id,
    category, requestId, allowOptionId, rejectOptionId,
  }).catch(() => {});
  // Optional ntfy fallback.
  if (config.ntfy) {
    try {
      const headers = { Title: title, Priority: priority };
      if (tags) headers.Tags = tags;
      if (actions) headers.Actions = actions;
      await fetch(config.ntfy, { method: "POST", headers, body: message });
    } catch { /* best-effort */ }
  }
}

// Push an approval alert with Approve/Reject buttons (when a public URL is set) so
// you can resolve a permission from the lock screen without opening the app.
function notifyPermission(session, event) {
  const allow = (event.options || []).find((o) => /allow/i.test(o.kind || o.optionId));
  const reject = (event.options || []).find((o) => /reject|deny/i.test(o.kind || o.optionId));

  let actions;
  if (config.publicUrl && event.requestId) {
    const base = config.publicUrl.replace(/\/$/, "");
    const parts = [];
    if (allow) parts.push(`http, Approve, ${base}/api/approve/${mintApprovalToken(session.id, event.requestId, allow.optionId)}, clear=true`);
    if (reject) parts.push(`http, Reject, ${base}/api/approve/${mintApprovalToken(session.id, event.requestId, reject.optionId)}, clear=true`);
    if (parts.length) actions = parts.join("; ");
  }
  pushNotify(session, {
    title: `${displayTitle(session)} — approval needed`,
    message: event.command || event.title || "Grok wants to run a tool",
    priority: "high", tags: "warning", actions,
    // Drives Approve/Reject buttons on the iOS notification itself.
    category: "PERMISSION",
    requestId: event.requestId,
    allowOptionId: allow?.optionId,
    rejectOptionId: reject?.optionId,
  });
}

// /api/health is unauthenticated by design, and used to spawn `grok --version` on
// every single request — so anyone reachable could exhaust the user's process table
// just by opening enough connections. One spawn a minute is plenty.
let versionCache = { value: null, at: 0 };
async function cachedGrokVersion() {
  const now = Date.now();
  if (versionCache.value !== null && now - versionCache.at < 60_000) return versionCache.value;
  const value = await grokVersion(config.grokBin);
  versionCache = { value, at: now };
  return value;
}

// Grok's ACP surfaces a raw JSON-RPC blob when its CLI isn't signed in (which can
// happen silently after grok auto-updates). Turn that into something actionable.
function friendlyTurnError(err) {
  const raw = String(err?.message || err);
  if (/Authentication required|no auth method|unauthenticated|not authenticated/i.test(raw)) {
    return "Grok Build isn't signed in on your computer. Open a terminal there, run `grok`, and sign in — then send this again.";
  }
  return raw;
}

// Live Activity driver: start on the lock screen when nobody's watching, flip to
// "waiting" on approvals, end when the turn does. All best-effort/fire-and-forget.
function laTurnStart(session) {
  if (!apns.enabled) return;
  const state = { phase: "working", detail: "Grok is working…" };
  if (apns.hasLaUpdateToken(session.id)) { apns.laUpdate(session.id, state).catch(() => {}); return; }
  if (session.subscriberCount > 0 || !apns.hasLaStartTokens) return;   // app open drives its own
  apns.laStart({
    attributes: { sessionName: displayTitle(session), sessionId: session.id },
    contentState: state,
    alertTitle: displayTitle(session),
    alertBody: "Grok started working.",
  }).catch(() => {});
}
function laWaiting(session, detail) {
  apns.laUpdate(session.id, { phase: "waiting", detail: detail || "Waiting for your approval" }).catch(() => {});
}
function laTurnEnd(session, phase, detail) {
  apns.laEnd(session.id, { phase, detail }).catch(() => {});
}

// One heads-up per session when the context window crosses 85% — after that a
// fresh session is the only real remedy, so say so while there's still room.
function warnContextIfNearlyFull(session) {
  const u = session.usage || {};
  if (!u.contextWindow || session._ctxWarned) return;
  const frac = u.contextTokens / u.contextWindow;
  if (frac < 0.85) return;
  session._ctxWarned = true;
  pushNotify(session, {
    title: displayTitle(session),
    message: `Context window ${Math.round(frac * 100)}% full — consider starting a fresh session soon.`,
    tags: "warning",
  });
}

// Kick off a Grok turn WITHOUT blocking the HTTP response. Events flow to the
// session's SSE subscribers (and history) as they arrive.
function startTurn(session, body) {
  return session.transport === "acp" ? startAcpTurn(session, body) : startHeadlessTurn(session, body);
}

function startHeadlessTurn(session, body) {
  const signal = session.beginTurn();
  session.emit({ kind: "turn_start", text: body.text, at: new Date().toISOString() });

  awake.acquire();   // don't let the machine sleep out from under a running turn

  runHeadlessTurn({
    grokBin: config.grokBin,
    prompt: body.text,
    sessionId: session.id,
    cwd: session.cwd,
    model: session.model,
    permissionMode: body.permissionMode || config.defaultPermissionMode,
    alwaysApprove: body.alwaysApprove ?? false,
    maxTurns: body.maxTurns,
    allow: body.allow || [],
    deny: body.deny || [],
    signal,
    onEvent: (event) => session.emit(event),
  })
    .then((result) => {
      // Grok emits its own `end`; add a bridge-level marker for the client's state machine.
      session.emit({ kind: "turn_complete", stopReason: result.stopReason });
      pushNotify(session, { title: displayTitle(session), message: "Grok finished the turn.", tags: "white_check_mark" });
    })
    .catch((err) => {
      session.emit({ kind: "error", message: friendlyTurnError(err) });
    })
    .finally(() => { awake.release(); session.endTurn(); store.save(); session.saveHistory(); });
}

// Lazily create + start the long-lived ACP process for a session, wiring its events
// into the session's SSE stream. Dropped (and recreated) if the process exits.
async function ensureAcp(session) {
  if (session.acp && session.acp.running) return session.acp;
  const acp = new AcpSession({
    grokBin: config.grokBin,
    cwd: session.cwd,
    model: session.model || undefined,
    effort: session.effort || undefined,
    home: grokHome,
    planMode: session.planMode,
    resumeSessionId: session.grokSessionId || undefined,
    onEvent: (event) => {
      if (event.kind === "closed") { session.acp = null; return; }
      if (event.kind === "permission_request") {
        if (session.autoApprove) {
          const allow = (event.options || []).find((o) => /allow/i.test(o.kind || o.optionId)) || event.options?.[0];
          if (allow) {
            const acp = session.acp, rid = event.requestId, oid = allow.optionId;
            setImmediate(() => acp?.resolvePermission(rid, oid)); // defer out of the stdout read handler
            return; // "always allow" — auto-approve, no card
          }
        }
        notifyPermission(session, event);
        laWaiting(session, event.command || event.title);
      }
      if (event.kind === "plan_review") {
        pushNotify(session, { title: `${displayTitle(session)} — plan ready`, message: "Grok drafted a plan; review to proceed.", priority: "high", tags: "clipboard" });
        laWaiting(session, "Plan ready to review");
      }
      session.emit(event);
    },
  });
  session.acp = acp;
  try {
    await acp.start();
  } catch (err) {
    // Dropping the reference without killing it leaked a live `grok agent stdio`
    // child per attempt — and a signed-out grok makes the phone retry repeatedly.
    try { acp.stop(); } catch { /* ignore */ }
    session.acp = null;
    throw err;
  }
  // Capture grok's ACP sessionId so we can session/load-resume it after a restart.
  if (acp.grokSessionId && acp.grokSessionId !== session.grokSessionId) {
    session.grokSessionId = acp.grokSessionId;
    store.save();
  }
  return acp;
}

function startAcpTurn(session, body) {
  session.beginTurn();
  session.emit({
    kind: "turn_start",
    text: body.displayText ?? body.text,          // the transcript shows what the user typed
    imageCount: body.imageCount || 0,
    at: new Date().toISOString(),
  });
  awake.acquire();   // don't let the machine sleep out from under a running turn
  laTurnStart(session);

  (async () => {
    try {
      const acp = await ensureAcp(session);
      const result = await acp.prompt(body.text);
      session.addUsage(result);                                    // fold grok's token report in
      session.emit({ kind: "usage", usage: session.usage });       // live meter update
      warnContextIfNearlyFull(session);
      session.emit({ kind: "turn_complete", stopReason: result.stopReason });
      pushNotify(session, { title: displayTitle(session), message: "Grok finished the turn.", tags: "white_check_mark" });
      laTurnEnd(session, "done", "Finished");
    } catch (err) {
      session.emit({ kind: "error", message: friendlyTurnError(err) });
      laTurnEnd(session, "error", "Something went wrong");
      try { session.acp?.stop(); } catch { /* ignore */ }   // don't orphan the child
      session.acp = null; // force a fresh process on the next turn
    } finally {
      awake.release();
      session.endTurn();
      store.save();
      session.saveHistory();
      // An effort change during a running turn can't reach the live process
      // (--reasoning-effort is a spawn argument), so recycle it now that the turn
      // is over; the next turn respawns with the new effort and resumes context
      // via session/load. Without this the chip claimed an effort the process
      // never used, for as long as it happened to live.
      if (session._recycleAcp) {
        session._recycleAcp = false;
        try { session.acp?.stop(); } catch { /* ignore */ }
        session.acp = null;
      }
      // After a plan is approved, auto-continue into execution once the plan turn ends.
      if (session._executeOnComplete) {
        session._executeOnComplete = false;
        startTurn(session, { text: "Proceed with the approved plan and implement it now." });
      }
    }
  })();
}

// Fire due schedules on this machine's local clock. The started turn behaves like
// any other: completion push, approval pushes, Live Activity — all apply.
startScheduler({
  schedules,
  sessions: store,
  fire: (session, s) => {
    pushNotify(session, { title: displayTitle(session), message: `Scheduled task started: ${s.prompt.slice(0, 90)}`, tags: "alarm_clock" });
    startTurn(session, { text: s.prompt });
  },
  onSkip: (session, s, why) => {
    pushNotify(session, { title: displayTitle(session), message: `Scheduled task skipped — ${why}.`, tags: "warning" });
  },
});

// Reap idle ACP processes; the next turn transparently resumes context via session/load.
if (config.transport === "acp") {
  const IDLE_MS = 20 * 60 * 1000;
  const timer = setInterval(() => {
    for (const s of store._byId.values()) {
      if (s.acp && s.status === "idle" && Date.now() - (s.acp.lastActivity || 0) > IDLE_MS) {
        try { s.acp.stop(); } catch { /* ignore */ }
        s.acp = null;
      }
    }
  }, 5 * 60 * 1000);
  timer.unref?.();
}

// ---- router ----------------------------------------------------------------

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const { pathname } = url;

  if (req.method === "OPTIONS") return send(res, 204, "");

  // Health is unauthenticated so a client can probe reachability before pairing.
  if (pathname === "/api/health") {
    const version = await cachedGrokVersion();
    return send(res, 200, {
      ok: true,
      name: config.name,
      host: hostname(),          // lets the phone name this computer in its bridge list
      grok: version,
      grokAvailable: Boolean(version),
    });
  }

  // Local pairing page — reveals the token + QR codes, so it is LOOPBACK-ONLY.
  if (pathname === "/pair") {
    if (!isLoopback(req)) {
      return send(res, 403, "Open this on the computer running the bridge: http://localhost:" + config.port + "/pair");
    }
    // Loopback isn't sufficient on its own: a browser on this machine reaches loopback
    // too, so a hostile page (or a rebound DNS name) would otherwise be able to read
    // the token straight out of this page.
    if (!isDirectLocalRequest(req)) {
      return send(res, 403, "Open this page directly in a browser on this computer.");
    }
    return send(res, 200, pairPageHTML(), { "content-type": "text/html; charset=utf-8" });
  }

  // Static test client (unauthenticated shell; it asks for the token in-page).
  if (!pathname.startsWith("/api/")) return serveStatic(res, pathname);

  // One-time approval links used by lock-screen push actions — authorized by the
  // single-use, decision-bound token in the URL, never the pairing token.
  const am = pathname.match(/^\/api\/approve\/([A-Za-z0-9_-]+)$/);
  if (am) {
    const rec = approvalTokens.get(am[1]);
    approvalTokens.delete(am[1]); // one-time, valid or not
    if (!rec || rec.exp < Date.now()) return send(res, 403, { error: "expired or invalid approval link" });
    const session = store.get(rec.sessionId);
    const ok = session && session.acp ? session.acp.resolvePermission(rec.requestId, rec.optionId) : false;
    return send(res, 200, { ok });
  }

  // Everything else under /api requires the pairing token.
  if (!authed(req, url)) {
    return send(res, 401, { error: "unauthorized", hint: "send Authorization: Bearer <token>" });
  }

  // Aggregate token/cost usage across every session (overall meter).
  if (pathname === "/api/usage" && req.method === "GET") {
    const sessions = store.list();
    const totals = { turns: 0, inputTokens: 0, outputTokens: 0, reasoningTokens: 0, cachedReadTokens: 0, totalTokens: 0, costUsdTicks: 0, apiDurationMs: 0 };
    let contextWindow = 0;
    for (const s of sessions) {
      const u = s.usage || {};
      for (const k of Object.keys(totals)) totals[k] += u[k] || 0;
      if (u.contextWindow) contextWindow = u.contextWindow;
    }
    return send(res, 200, { totals, sessionCount: sessions.length, contextWindow });
  }

  // Register this phone's APNs device token so the bridge can push alerts.
  if (pathname === "/api/devices" && req.method === "POST") {
    const body = await readJson(req).catch(() => ({}));
    const ok = apns.addDevice(body.token);
    return send(res, ok ? 200 : 400, { ok, push: apns.enabled });
  }

  // ActivityKit push tokens: "start-token" lets the bridge START a lock-screen
  // activity with the app closed (iOS 17.2+); "update-token" drives one session's
  // running activity.
  if (pathname === "/api/live-activity" && req.method === "POST") {
    const body = await readJson(req).catch(() => ({}));
    const ok = body.kind === "start-token" ? apns.addLaStartToken(body.token)
      : body.kind === "update-token" ? apns.setLaUpdateToken(body.sessionId, body.token)
      : false;
    return send(res, ok ? 200 : 400, { ok });
  }

  // Directory browser for the phone's working-directory picker. Home-jailed: this
  // is a convenience surface, and the picker's text field still accepts any path.
  if (pathname === "/api/fs/dirs" && req.method === "GET") {
    const home = homedir();
    const requested = url.searchParams.get("path") || home;
    const full = resolvePath(requested);
    if (full !== home && !full.startsWith(home + sep)) {
      return send(res, 403, { error: "outside your home folder — type the path instead" });
    }
    try {
      const entries = await readdir(full, { withFileTypes: true });
      const dirs = entries
        .filter((e) => e.isDirectory() && !e.name.startsWith("."))
        .map((e) => ({ name: e.name, path: join(full, e.name) }))
        .sort((a, b) => a.name.localeCompare(b.name))
        .slice(0, 300);
      return send(res, 200, { path: full, parent: full === home ? null : dirname(full), dirs });
    } catch {
      return send(res, 404, { error: "can't read that folder" });
    }
  }

  // Scheduled tasks.
  if (pathname === "/api/schedules" && req.method === "GET") {
    return send(res, 200, { schedules: schedules.list() });
  }
  if (pathname === "/api/schedules" && req.method === "POST") {
    const body = await readJson(req).catch(() => ({}));
    if (!store.get(body.sessionId)) return send(res, 404, { error: "no such session" });
    const made = schedules.create(body);
    if (typeof made === "string") return send(res, 400, { error: made });
    return send(res, 201, made);
  }
  const sm = pathname.match(/^\/api\/schedules\/([0-9a-fA-F-]{36})$/);
  if (sm && req.method === "PATCH") {
    const body = await readJson(req).catch(() => ({}));
    const updated = schedules.update(sm[1], body);
    return updated ? send(res, 200, updated) : send(res, 404, { error: "no such schedule" });
  }
  if (sm && req.method === "DELETE") {
    return schedules.delete(sm[1]) ? send(res, 200, { ok: true }) : send(res, 404, { error: "no such schedule" });
  }

  // /api/sessions
  if (pathname === "/api/sessions" && req.method === "GET") {
    return send(res, 200, { sessions: store.list() });
  }
  if (pathname === "/api/sessions" && req.method === "POST") {
    const body = await readJson(req).catch(() => ({}));
    const session = store.create({
      cwd: body.cwd || config.defaultCwd,
      model: body.model || config.defaultModel,
      effort: body.effort,
      transport: body.transport || config.transport,
      planMode: body.planMode ?? false,
      autoApprove: body.autoApprove ?? false,
      title: body.title,
    });
    return send(res, 201, session.toJSON());
  }

  // Answer a pending ACP permission request: /api/sessions/:id/permissions/:requestId
  const pm = pathname.match(/^\/api\/sessions\/([0-9a-fA-F-]{36})\/permissions\/([^/]+)$/);
  if (pm && req.method === "POST") {
    const session = store.get(pm[1]);
    if (!session) return send(res, 404, { error: "no such session" });
    const body = await readJson(req).catch(() => ({}));
    const ok = session.acp ? session.acp.resolvePermission(pm[2], body.optionId ?? null) : false;
    // A dead process or an already-answered request used to return 200 {ok:false},
    // which every client read as success — the card said "approved" while grok
    // wasn't waiting on anything. Fail loudly and only honor side effects on success.
    if (!ok) return send(res, 409, { error: "that approval is no longer pending" });
    if (body.always) { session.autoApprove = true; store.save(); } // "always allow" for this session
    return send(res, 200, { ok: true });
  }

  // Approve/reject a plan: /api/sessions/:id/plan/:requestId  { approved }
  const plm = pathname.match(/^\/api\/sessions\/([0-9a-fA-F-]{36})\/plan\/([^/]+)$/);
  if (plm && req.method === "POST") {
    const session = store.get(plm[1]);
    if (!session) return send(res, 404, { error: "no such session" });
    const body = await readJson(req).catch(() => ({}));
    const approved = body.approved !== false;
    const ok = session.acp ? session.acp.resolvePlan(plm[2], approved) : false;
    if (!ok) return send(res, 409, { error: "that plan review is no longer pending" });
    // Only arm the auto-continue when the approval actually landed. Setting it first
    // meant a failed approve left the flag behind, and some LATER unrelated turn
    // would suddenly follow up with "proceed with the approved plan".
    if (approved) session._executeOnComplete = true; // auto-run once the plan turn ends
    return send(res, 200, { ok: true });
  }

  // /api/sessions/:id[/...]
  const m = pathname.match(/^\/api\/sessions\/([0-9a-fA-F-]{36})(?:\/(\w+))?$/);
  if (m) {
    const session = store.get(m[1]);
    const sub = m[2];
    if (!session) return send(res, 404, { error: "no such session" });

    if (!sub && req.method === "GET") return send(res, 200, session.toJSON());

    if (!sub && req.method === "DELETE") {
      store.delete(m[1]);
      schedules.removeForSession(m[1]);   // orphaned schedules would mis-fire forever
      apns.clearLaSession(m[1]);
      return send(res, 200, { ok: true });
    }

    if (!sub && req.method === "PATCH") {
      const body = await readJson(req).catch(() => ({}));
      if (typeof body.title === "string" && body.title.trim()) store.rename(m[1], body.title.trim());
      if (typeof body.folder === "string") { session.folder = body.folder.trim(); store.save(); }
      return send(res, 200, session.toJSON());
    }

    if (sub === "messages" && req.method === "POST") {
      const body = await readJson(req).catch(() => ({}));
      const text = typeof body.text === "string" ? body.text : "";
      const images = Array.isArray(body.images) ? body.images : [];
      if (!text.trim() && !images.length) {
        return send(res, 400, { error: "missing 'text'" });
      }
      if (session.status === "running") {
        return send(res, 409, { error: "a turn is already running in this session" });
      }

      // Attached images: grok's ACP rejects image content blocks (it advertises
      // promptCapabilities.image: false), but its read tool IS vision-capable — so
      // save each image to disk and point grok at the files in the prompt text.
      if (images.length) {
        if (session.transport !== "acp") return send(res, 400, { error: "images need the acp transport" });
        if (images.length > 3) return send(res, 400, { error: "up to 3 images per message" });
        const paths = [];
        for (const [i, img] of images.entries()) {
          const mime = String(img?.mimeType || "");
          const ext = mime === "image/png" ? "png" : mime === "image/jpeg" ? "jpg" : null;
          const data = typeof img?.data === "string" ? img.data : "";
          if (!ext || !data || data.length > 14_000_000) {   // ~10MB decoded
            return send(res, 400, { error: "images must be jpeg/png, up to ~10MB each" });
          }
          let buf;
          try { buf = Buffer.from(data, "base64"); } catch { return send(res, 400, { error: "bad image data" }); }
          if (!buf.length) return send(res, 400, { error: "bad image data" });
          const file = join(UPLOAD_DIR, `${session.id.slice(0, 8)}-${Date.now()}-${i}.${ext}`);
          try { await writeFile(file, buf); } catch { return send(res, 500, { error: "couldn't save the image" }); }
          paths.push(file);
        }
        const noun = paths.length === 1 ? "an image" : `${paths.length} images`;
        const listing = paths.map((p) => `  - ${p}`).join("\n");
        const note = `\n\n[The user attached ${noun}, saved on this machine at:\n${listing}\nView ${paths.length === 1 ? "it" : "them"} with your image-capable read tool before answering.]`;
        startTurn(session, { text: (text.trim() || "See the attached image.") + note, displayText: text, imageCount: paths.length });
        return send(res, 202, { ok: true, sessionId: session.id, turn: session.turnCount });
      }

      startTurn(session, body);
      return send(res, 202, { ok: true, sessionId: session.id, turn: session.turnCount });
    }

    if (sub === "cancel" && req.method === "POST") {
      const cancelled = session.cancel();
      return send(res, 200, { ok: true, cancelled });
    }

    // Live per-session settings: /api/sessions/:id/config { planMode?, effort?, autoApprove? }
    if (sub === "config" && req.method === "POST") {
      const body = await readJson(req).catch(() => ({}));
      if (typeof body.planMode === "boolean") {
        session.planMode = body.planMode;
        if (session.acp && session.acp.running) session.acp.setMode(body.planMode ? "plan" : "default");
      }
      if (typeof body.effort === "string") {
        session.effort = body.effort || undefined;
        // Apply next turn: drop an idle ACP process so it respawns with the new effort
        // (context resumes via session/load). Mid-turn, mark it for recycling when the
        // turn ends — otherwise the change silently never applied while the long-lived
        // process survived (which, with 20-minute idle reaping, could be the whole day).
        if (session.acp && session.status === "idle") { try { session.acp.stop(); } catch { /* ignore */ } session.acp = null; }
        else if (session.acp) session._recycleAcp = true;
      }
      if (typeof body.autoApprove === "boolean") session.autoApprove = body.autoApprove;
      store.save();
      return send(res, 200, session.toJSON());
    }

    // Read-only project browser, jailed to the session's working directory:
    // /api/sessions/:id/files?path=<rel>  → directory listing
    // /api/sessions/:id/file?path=<rel>   → text file content (binary detected)
    if ((sub === "files" || sub === "file") && req.method === "GET") {
      const base = session.cwd ? resolvePath(session.cwd) : null;
      if (!base) return send(res, 400, { error: "this session has no working directory" });
      const rel = url.searchParams.get("path") || "";
      const full = resolvePath(base, "." + sep + rel);
      if (full !== base && !full.startsWith(base + sep)) return send(res, 403, { error: "outside the session folder" });

      if (sub === "files") {
        try {
          const entries = await readdir(full, { withFileTypes: true });
          const out = [];
          for (const e of entries) {
            if (e.name === ".git") continue;                       // noise, and huge
            let size = 0;
            if (e.isFile()) { try { size = (await stat(join(full, e.name))).size; } catch { /* ignore */ } }
            out.push({ name: e.name, dir: e.isDirectory(), size });
          }
          out.sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name));
          return send(res, 200, { path: rel, entries: out.slice(0, 500) });
        } catch {
          return send(res, 404, { error: "can't read that folder" });
        }
      }

      try {
        const st = await stat(full);
        if (!st.isFile()) return send(res, 400, { error: "not a file" });
        const LIMIT = 262_144;   // 256KB is plenty for a phone screen
        const buf = await readFile(full);
        const head = buf.subarray(0, Math.min(buf.length, 8192));
        if (head.includes(0)) return send(res, 200, { path: rel, size: st.size, binary: true });
        const truncated = buf.length > LIMIT;
        return send(res, 200, {
          path: rel, size: st.size, binary: false, truncated,
          content: buf.subarray(0, LIMIT).toString("utf8"),
        });
      } catch {
        return send(res, 404, { error: "can't read that file" });
      }
    }

    // Review what Grok changed: /api/sessions/:id/git  (?file=… for one file's diff)
    if (sub === "git" && req.method === "GET") {
      const file = url.searchParams.get("file");
      if (file) return send(res, 200, { diff: await git.diff(session.cwd, file) });
      return send(res, 200, await git.status(session.cwd));
    }
    // { action: "commit", message } | { action: "discard" }
    if (sub === "git" && req.method === "POST") {
      const body = await readJson(req).catch(() => ({}));
      if (body.action === "commit") {
        const message = String(body.message || "").trim();
        if (!message) return send(res, 400, { error: "missing commit message" });
        return send(res, 200, await git.commit(session.cwd, message));
      }
      if (body.action === "discard") return send(res, 200, await git.discard(session.cwd));
      return send(res, 400, { error: "unknown action" });
    }

    if (sub === "stream" && req.method === "GET") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache, no-transform",
        connection: "keep-alive",
        "access-control-allow-origin": "*",
        "x-accel-buffering": "no",
      });
      res.write("retry: 3000\n\n");
      const lastEventId = Number(req.headers["last-event-id"] || url.searchParams.get("lastEventId") || 0);
      session.subscribe(res, lastEventId);
      // Heartbeat so intermediaries and the phone keep the connection open.
      const ping = setInterval(() => res.write(": ping\n\n"), 15000);
      res.on("close", () => clearInterval(ping));
      return;
    }
  }

  return send(res, 404, { error: "not found" });
}

// ---- boot ------------------------------------------------------------------

const handler = (req, res) => {
  handle(req, res).catch((err) => {
    if (!res.headersSent) send(res, 500, { error: String(err.message || err) });
    else res.end();
  });
};

const useTls = Boolean(config.tlsCert && config.tlsKey);
const server = useTls
  ? createHttpsServer({ cert: readFileSync(config.tlsCert), key: readFileSync(config.tlsKey) }, handler)
  : createServer(handler);
const scheme = useTls ? "https" : "http";

// Bind dual-stack when host is 0.0.0.0 so `localhost` works in browsers that try
// IPv6 (::1) first (e.g. Safari). "::" still accepts IPv4, so LAN/Tailscale work.
const listenHost = config.host === "0.0.0.0" ? "::" : config.host;
// Without this every live `grok agent stdio` child is orphaned when the bridge is
// stopped (Ctrl+C, launchd, a reinstall), each still holding a cwd inside a repo.
let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const summary of store.list()) {
    try { store.get(summary.id)?.acp?.stop(); } catch { /* ignore */ }
  }
  try { bonjour?.kill(); } catch { /* ignore */ }
  try { awake.release(); } catch { /* ignore */ }
  process.exit(0);
}

// Advertise the bridge on the local network (macOS dns-sd ships with the OS, so
// this stays zero-dependency). The phone's pairing screen lists nearby bridges so
// the address doesn't have to be typed; the token is still required to connect.
let bonjour = null;
function advertiseBonjour() {
  if (process.platform !== "darwin") return;
  if (["127.0.0.1", "::1", "localhost"].includes(String(config.host))) return;   // not reachable anyway
  try {
    bonjour = spawn("/usr/bin/dns-sd", ["-R", `TethrX (${hostname()})`, "_tethrx._tcp", ".", String(config.port)], { stdio: "ignore" });
    bonjour.on("error", () => { bonjour = null; });
    bonjour.on("exit", () => { bonjour = null; });
  } catch { bonjour = null; }
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
// A stray rejection should not take the daemon down and strand the phone.
process.on("unhandledRejection", (err) => console.error("[bridge] unhandled rejection:", err));

server.listen(config.port, listenHost, async () => {
  advertiseBonjour();
  const version = await grokVersion(config.grokBin);
  const reachable = config.host === "0.0.0.0" ? "<this-machine-ip>" : config.host;
  console.log(`\n  ${config.name} bridge running`);
  console.log(`  ├─ listening   ${scheme}://${config.host}:${config.port}${bonjour ? "  (visible nearby as _tethrx._tcp)" : ""}`);
  console.log(`  ├─ grok        ${version || "NOT FOUND — check GROK_BIN"}  (${config.grokBin})`);
  console.log(`  ├─ transport   ${config.transport}${config.transport === "acp" ? ` (approve/reject: ${grokHome ? "on" : "off"})` : ""}`);
  console.log(`  ├─ default cwd ${config.defaultCwd}`);
  console.log(`  ├─ web client  ${scheme}://${reachable}:${config.port}/`);
  console.log(`  ├─ pair phone  ${scheme}://localhost:${config.port}/pair  (open here, scan in the app)`);
  console.log(`  ├─ push (apns) ${apns.enabled ? `on  (${apns.tokens.length} device${apns.tokens.length === 1 ? "" : "s"})` : "off  (set apns key in config.json)"}`);
  console.log(`  ├─ push (ntfy) ${config.ntfy || "off  (set GROK_REMOTE_NTFY)"}`);
  if (config.publicUrl) console.log(`  ├─ public url  ${config.publicUrl}  (lock-screen approve/reject)`);
  console.log(`  └─ pairing token:\n\n     ${config.token}\n`);
  if (config.host === "127.0.0.1") {
    console.log("  (loopback only — set GROK_REMOTE_HOST=0.0.0.0 or use Tailscale to reach it from your phone)\n");
  }
});
