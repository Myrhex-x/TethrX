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
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize as normPath, sep } from "node:path";
import { timingSafeEqual, randomBytes } from "node:crypto";

import { config } from "./config.mjs";
import { SessionStore } from "./sessions.mjs";
import { runHeadlessTurn, grokVersion } from "./grok.mjs";
import { ensureAskGrokHome, AcpSession } from "./acp.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "..", "public");
const store = new SessionStore(join(config.stateDir, "sessions.json"));

// Single-use, decision-bound tokens for lock-screen approval links, so the full
// pairing token is never embedded in an ntfy notification.
const approvalTokens = new Map(); // token -> { sessionId, requestId, optionId, exp }
function mintApprovalToken(sessionId, requestId, optionId) {
  const t = randomBytes(18).toString("base64url");
  approvalTokens.set(t, { sessionId, requestId, optionId, exp: Date.now() + 15 * 60 * 1000 });
  return t;
}

// For ACP + ask-mode, run Grok under a redirected HOME that enables per-tool prompts
// without touching the user's global ~/.grok/config.toml. Built once at startup.
const grokHome = config.transport === "acp" && config.askPermission
  ? ensureAskGrokHome(config.stateDir)
  : null;

// ---- helpers ---------------------------------------------------------------

function send(res, status, body, headers = {}) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "content-type": typeof body === "string" ? "text/plain; charset=utf-8" : "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-allow-methods": "GET, POST, PATCH, DELETE, OPTIONS",
    ...headers,
  });
  res.end(payload);
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
async function pushNotify(session, { title, message, priority = "default", tags, actions }) {
  if (!config.ntfy || session.subscriberCount > 0) return;
  try {
    const headers = { Title: title, Priority: priority };
    if (tags) headers.Tags = tags;
    if (actions) headers.Actions = actions;
    await fetch(config.ntfy, { method: "POST", headers, body: message });
  } catch { /* best-effort */ }
}

// Push an approval alert with Approve/Reject buttons (when a public URL is set) so
// you can resolve a permission from the lock screen without opening the app.
function notifyPermission(session, event) {
  let actions;
  if (config.publicUrl && event.requestId) {
    const base = config.publicUrl.replace(/\/$/, "");
    const allow = (event.options || []).find((o) => /allow/i.test(o.kind || o.optionId));
    const reject = (event.options || []).find((o) => /reject|deny/i.test(o.kind || o.optionId));
    const parts = [];
    if (allow) parts.push(`http, Approve, ${base}/api/approve/${mintApprovalToken(session.id, event.requestId, allow.optionId)}, clear=true`);
    if (reject) parts.push(`http, Reject, ${base}/api/approve/${mintApprovalToken(session.id, event.requestId, reject.optionId)}, clear=true`);
    if (parts.length) actions = parts.join("; ");
  }
  pushNotify(session, {
    title: `${session.title} — approval needed`,
    message: event.command || event.title || "Grok wants to run a tool",
    priority: "high", tags: "warning", actions,
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
      pushNotify(session, { title: session.title, message: "Grok finished the turn.", tags: "white_check_mark" });
    })
    .catch((err) => {
      session.emit({ kind: "error", message: String(err.message || err) });
    })
    .finally(() => { session.endTurn(); store.save(); session.saveHistory(); });
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
      }
      if (event.kind === "plan_review") {
        pushNotify(session, { title: `${session.title} — plan ready`, message: "Grok drafted a plan; review to proceed.", priority: "high", tags: "clipboard" });
      }
      session.emit(event);
    },
  });
  session.acp = acp;
  await acp.start();
  // Capture grok's ACP sessionId so we can session/load-resume it after a restart.
  if (acp.grokSessionId && acp.grokSessionId !== session.grokSessionId) {
    session.grokSessionId = acp.grokSessionId;
    store.save();
  }
  return acp;
}

function startAcpTurn(session, body) {
  session.beginTurn();
  session.emit({ kind: "turn_start", text: body.text, at: new Date().toISOString() });

  (async () => {
    try {
      const acp = await ensureAcp(session);
      const result = await acp.prompt(body.text);
      session.emit({ kind: "turn_complete", stopReason: result.stopReason });
      pushNotify(session, { title: session.title, message: "Grok finished the turn.", tags: "white_check_mark" });
    } catch (err) {
      session.emit({ kind: "error", message: String(err.message || err) });
      session.acp = null; // force a fresh process on the next turn
    } finally {
      session.endTurn();
      store.save();
      session.saveHistory();
      // After a plan is approved, auto-continue into execution once the plan turn ends.
      if (session._executeOnComplete) {
        session._executeOnComplete = false;
        startTurn(session, { text: "Proceed with the approved plan and implement it now." });
      }
    }
  })();
}

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
    const version = await grokVersion(config.grokBin);
    return send(res, 200, {
      ok: true,
      name: config.name,
      grok: version,
      grokAvailable: Boolean(version),
    });
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
    if (body.always) { session.autoApprove = true; store.save(); } // "always allow" for this session
    const ok = session.acp ? session.acp.resolvePermission(pm[2], body.optionId ?? null) : false;
    return send(res, 200, { ok });
  }

  // Approve/reject a plan: /api/sessions/:id/plan/:requestId  { approved }
  const plm = pathname.match(/^\/api\/sessions\/([0-9a-fA-F-]{36})\/plan\/([^/]+)$/);
  if (plm && req.method === "POST") {
    const session = store.get(plm[1]);
    if (!session) return send(res, 404, { error: "no such session" });
    const body = await readJson(req).catch(() => ({}));
    const approved = body.approved !== false;
    if (approved) session._executeOnComplete = true; // auto-run once the plan turn ends
    const ok = session.acp ? session.acp.resolvePlan(plm[2], approved) : false;
    return send(res, 200, { ok });
  }

  // /api/sessions/:id[/...]
  const m = pathname.match(/^\/api\/sessions\/([0-9a-fA-F-]{36})(?:\/(\w+))?$/);
  if (m) {
    const session = store.get(m[1]);
    const sub = m[2];
    if (!session) return send(res, 404, { error: "no such session" });

    if (!sub && req.method === "GET") return send(res, 200, session.toJSON());

    if (!sub && req.method === "DELETE") { store.delete(m[1]); return send(res, 200, { ok: true }); }

    if (!sub && req.method === "PATCH") {
      const body = await readJson(req).catch(() => ({}));
      if (typeof body.title === "string" && body.title.trim()) store.rename(m[1], body.title.trim());
      return send(res, 200, session.toJSON());
    }

    if (sub === "messages" && req.method === "POST") {
      const body = await readJson(req).catch(() => ({}));
      if (!body.text || typeof body.text !== "string") {
        return send(res, 400, { error: "missing 'text'" });
      }
      if (session.status === "running") {
        return send(res, 409, { error: "a turn is already running in this session" });
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
        // (context resumes via session/load).
        if (session.acp && session.status === "idle") { try { session.acp.stop(); } catch { /* ignore */ } session.acp = null; }
      }
      if (typeof body.autoApprove === "boolean") session.autoApprove = body.autoApprove;
      store.save();
      return send(res, 200, session.toJSON());
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

server.listen(config.port, config.host, async () => {
  const version = await grokVersion(config.grokBin);
  const reachable = config.host === "0.0.0.0" ? "<this-machine-ip>" : config.host;
  console.log(`\n  ${config.name} bridge running`);
  console.log(`  ├─ listening   ${scheme}://${config.host}:${config.port}`);
  console.log(`  ├─ grok        ${version || "NOT FOUND — check GROK_BIN"}  (${config.grokBin})`);
  console.log(`  ├─ transport   ${config.transport}${config.transport === "acp" ? ` (approve/reject: ${grokHome ? "on" : "off"})` : ""}`);
  console.log(`  ├─ default cwd ${config.defaultCwd}`);
  console.log(`  ├─ web client  ${scheme}://${reachable}:${config.port}/`);
  console.log(`  ├─ push (ntfy) ${config.ntfy || "off  (set GROK_REMOTE_NTFY)"}`);
  if (config.publicUrl) console.log(`  ├─ public url  ${config.publicUrl}  (lock-screen approve/reject)`);
  console.log(`  └─ pairing token:\n\n     ${config.token}\n`);
  if (config.host === "127.0.0.1") {
    console.log("  (loopback only — set GROK_REMOTE_HOST=0.0.0.0 or use Tailscale to reach it from your phone)\n");
  }
});
