// ACP transport: drives `grok agent stdio` over JSON-RPC for a rich session —
// streaming tool calls, tool output, plans, thoughts, and (optionally) blocking
// permission requests the phone can approve/reject.
//
// Enabling per-tool prompts requires grok config `support_permission = true` +
// a prompting `permission_mode`. Rather than edit the user's global ~/.grok/
// config.toml, we run grok under a redirected HOME whose ~/.grok SYMLINKS every
// real file except config.toml, which we supply with prompting turned on.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import {
  existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync, rmSync, symlinkSync,
  lstatSync, copyFileSync, renameSync,
} from "node:fs";

const REAL_GROK = join(homedir(), ".grok");
const OUTPUT_LIMIT = 8000;   // cap tool output per update so a chatty build can't flood the phone
const HANDSHAKE_TIMEOUT = 120000;  // initialize / session-new / session-load must not hang forever
// A turn with no protocol traffic at all for this long is wedged, not slow: grok streams
// thoughts and tool updates continuously while it works. Without this, a hung child left
// `prompt()` awaiting forever, the session stuck "running", and the caffeinate assertion
// held, so the Mac never slept again. A pending permission is a legitimate wait and is
// excluded, because the user may answer it hours later.
const STALL_TIMEOUT = 30 * 60 * 1000;

/**
 * Build (or rebuild) a HOME dir whose ~/.grok mirrors the real one via symlinks but
 * supplies a config.toml with per-tool permission prompts enabled. Returns the HOME
 * path to pass as env.HOME, or null if the real ~/.grok can't be found.
 */
// Files grok rewrites in place (atomically), which turns our symlink into a real file
// living only inside the redirected home. These must never be thrown away.
const MUTABLE_STATE = ["auth.json"];

/** Does a path exist at all (including as a broken symlink)? */
function present(p) {
  try { lstatSync(p); return true; } catch { return false; }
}
function isRealFile(p) {
  try { return lstatSync(p).isFile(); } catch { return false; }
}

/**
 * Grok refreshes its OAuth token by atomically rewriting auth.json — which REPLACES
 * our symlink with a real file inside the redirected home. Because refresh tokens
 * rotate (single use), that file becomes the only valid credential: the copy left in
 * the real ~/.grok is already spent. Wiping the redirected home on restart therefore
 * signed grok out permanently. Promote anything grok wrote back to the real ~/.grok,
 * then re-link, so the bridge and the user's own terminal stay on one credential set.
 */
function promoteRefreshedState(dotgrok) {
  for (const name of MUTABLE_STATE) {
    const mirrored = join(dotgrok, name);
    if (!isRealFile(mirrored)) continue;               // still a symlink => nothing refreshed
    const real = join(REAL_GROK, name);
    try {
      // Only promote a file that is actually a usable credential. If grok was killed
      // (or the disk filled) mid-rewrite, the mirrored copy can be truncated or empty —
      // copying that over the real one destroys the only working credential, because
      // refresh tokens rotate and the old one is already spent.
      const raw = readFileSync(mirrored, "utf8");
      if (!raw.trim()) continue;
      JSON.parse(raw);                                 // must be parseable, or skip
      try { if (existsSync(real)) copyFileSync(real, real + ".bak"); } catch { /* best-effort */ }
      const tmp = real + ".tmp";
      writeFileSync(tmp, raw, { mode: 0o600 });
      renameSync(tmp, real);                           // atomic swap, never a partial file
      rmSync(mirrored, { force: true });               // drop it so we can re-symlink below
    } catch {
      // Anything suspect: leave BOTH files untouched rather than risk the credential.
    }
  }
}

export function ensureAskGrokHome(stateDir) {
  if (!existsSync(REAL_GROK)) return null;
  const home = join(stateDir, "grok-home");
  const dotgrok = join(home, ".grok");
  mkdirSync(dotgrok, { recursive: true });

  // NEVER rm -rf this directory: grok may have refreshed credentials into it.
  promoteRefreshedState(dotgrok);

  for (const entry of readdirSync(REAL_GROK)) {
    if (entry === "config.toml") continue;             // we provide our own
    const link = join(dotgrok, entry);
    if (present(link)) continue;                       // keep existing links / grok's own files
    try { symlinkSync(join(REAL_GROK, entry), link); } catch { /* skip */ }
  }

  let base = "";
  try { base = readFileSync(join(REAL_GROK, "config.toml"), "utf8"); } catch { /* none */ }
  writeFileSync(join(dotgrok, "config.toml"), deriveAskConfig(base));
  return home;
}

// Preserve the user's config but force prompting on.
function deriveAskConfig(base) {
  const kept = base
    .split("\n")
    .filter((l) => !/^\s*permission_mode\s*=/.test(l) && !/^\s*support_permission\s*=/.test(l))
    .join("\n")
    .trimEnd();
  let out = kept + "\n";
  if (/^\[ui\]\s*$/m.test(out)) out = out.replace(/^\[ui\]\s*$/m, '[ui]\npermission_mode = "default"');
  else out += '\n[ui]\npermission_mode = "default"\n';
  if (/^\[features\]\s*$/m.test(out)) out = out.replace(/^\[features\]\s*$/m, "[features]\nsupport_permission = true");
  else out += "\n[features]\nsupport_permission = true\n";
  return out;
}

/** One long-lived `grok agent stdio` process backing a single bridge session. */
export class AcpSession {
  constructor({ grokBin, cwd, model, effort, home, planMode, resumeSessionId, onEvent }) {
    this.grokBin = grokBin;
    this.cwd = cwd;
    this.model = model;
    this.effort = effort;
    this.home = home;
    this.planMode = planMode || false;
    this.resumeSessionId = resumeSessionId || null;   // grok sessionId to session/load
    this.onEvent = onEvent;

    this.proc = null;
    this.rl = null;
    this._replaying = false;         // true while session/load echoes prior history
    this.grokSessionId = null;
    this.contextWindow = null;       // model's max context tokens (from initialize)
    this.currentModelId = null;      // grok's chosen model when we don't pin one
    this.capabilities = null;        // initialize.agentCapabilities — the gate for anything version-specific
    this.agentVersion = null;        // initialize._meta.agentVersion, e.g. "1.0.0"
    this.availableCommands = [];     // grok's slash commands (/compact, /context, skills…)
    this.lastActivity = Date.now();
    this._nextId = 1;
    this._pending = new Map();       // our request id -> {resolve, reject}
    this._permissions = new Map();   // permission requestId (string) -> grok's json-rpc id
    this._plans = new Map();         // exit_plan requestId (string) -> grok's json-rpc id
    this._unhandled = new Set();     // notification methods we have already warned about
    this._stallTimer = null;
    // Grok numbers its JSON-RPC ids from zero PER PROCESS, so permission request ids
    // repeat across restarts — across real transcripts here they are only 0..3, with 0
    // in most sessions. A card left over from a dead process would otherwise resolve
    // whichever unrelated request reused that number after a respawn. Namespacing the
    // id with a per-process nonce makes a stale approval fail closed instead.
    this._nonce = randomBytes(4).toString("hex");
  }

  /** Stable, process-unique id for a grok JSON-RPC request awaiting our answer. */
  _tag(id) { return `${this._nonce}.${id}`; }

  async start() {
    // `-m` and `--reasoning-effort` are options of `grok agent`, not of the `stdio`
    // subcommand — they must precede `stdio` or grok exits with "unexpected argument".
    const args = ["agent"];
    if (this.model) args.push("-m", this.model);
    if (this.effort) args.push("--reasoning-effort", this.effort);
    args.push("stdio");

    const env = { ...process.env };
    if (this.home) env.HOME = this.home;
    // Under RUST_LOG=debug grok prints its own xAI bearer token into stderr, which we
    // tee into the shareable log ring served by GET /api/logs. Never inherit it.
    delete env.RUST_LOG;

    this.proc = spawn(this.grokBin, args, { cwd: this.cwd, stdio: ["pipe", "pipe", "pipe"], env });
    this.proc.stderr.on("data", (d) => console.error("[grok stderr] " + d.toString().trimEnd())); // drain + surface
    this.rl = createInterface({ input: this.proc.stdout });
    this.rl.on("line", (line) => this._onLine(line));
    this.proc.on("close", () => {
      // Nothing else settles in-flight requests, so a grok that dies mid-turn used to
      // leave `prompt()` awaiting forever: the turn's finally never ran, the session
      // stayed "running", and every later message got a permanent 409.
      this._clearStallTimer();
      this._failPending(new Error("grok agent exited"));
      // `acp` identifies WHICH process died. The turn's error path installs a fresh
      // AcpSession synchronously, before this fires — so an untagged event made the
      // dying process null out its live replacement, after which every approval 409'd
      // and grok blocked forever on a tool nobody could answer.
      this.onEvent({ kind: "closed", acp: this });
    });
    this.proc.on("error", (e) => this.onEvent({ kind: "error", message: `grok agent failed: ${e.message}` }));

    const init = await this._request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    }, HANDSHAKE_TIMEOUT);
    // Capture the active model's context window so the phone can show a real meter.
    try {
      const ms = init?._meta?.modelState;
      const cur = ms?.availableModels?.find((m) => m.modelId === ms?.currentModelId) || ms?.availableModels?.[0];
      this.contextWindow = cur?._meta?.totalContextTokens || this.contextWindow;
      this.currentModelId = ms?.currentModelId || this.currentModelId;
    } catch { /* usage meter is best-effort */ }
    // Everything version-specific gates on these rather than on a version string.
    this.capabilities = init?.agentCapabilities || null;
    this.agentVersion = init?._meta?.agentVersion || null;
    // grok 1.0.0 hands the command roster back at initialize; older builds only ever
    // send it later via available_commands_update.
    const atInit = init?._meta?.availableCommands;
    if (Array.isArray(atInit) && atInit.length) this._adoptCommands(atInit);

    // Resume prior context if we have a grok sessionId; otherwise start fresh.
    if (this.resumeSessionId) {
      try {
        // session/load replays the ENTIRE prior conversation as session/update
        // notifications before it resolves. The bridge already keeps that history
        // itself (and replays it to clients over SSE), so letting the replay through
        // appended a second copy of the whole conversation to the transcript every
        // time the process was recreated — after idle reaping, a crash, or a restart.
        // Grok still gets its context; only the echo to our clients is suppressed.
        this._replaying = true;
        await this._request("session/load", { sessionId: this.resumeSessionId, cwd: this.cwd, mcpServers: [] }, HANDSHAKE_TIMEOUT);
        this.grokSessionId = this.resumeSessionId;
      } catch (e) {
        // Falling back to a fresh session silently DISCARDS the user's context, so say
        // so rather than letting the transcript quietly restart with no explanation.
        console.error(`[acp] could not resume grok session ${this.resumeSessionId}: ${e.message}`);
        const res = await this._request("session/new", { cwd: this.cwd, mcpServers: [] }, HANDSHAKE_TIMEOUT);
        this.grokSessionId = res?.sessionId;
        this.onEvent({ kind: "log", level: "warn", message: "Could not restore this session's context in Grok; continuing with a fresh one." });
      } finally {
        this._replaying = false;
      }
    } else {
      const res = await this._request("session/new", { cwd: this.cwd, mcpServers: [] }, HANDSHAKE_TIMEOUT);
      this.grokSessionId = res?.sessionId;
    }

    if (this.planMode) {
      try { await this._request("session/set_mode", { sessionId: this.grokSessionId, modeId: "plan" }, 30000); } catch { /* mode optional */ }
    }
    return this.grokSessionId;
  }

  setMode(modeId) {
    const id = this._nextId++;
    try { this._send({ jsonrpc: "2.0", id, method: "session/set_mode", params: { sessionId: this.grokSessionId, modeId } }); } catch { /* ignore */ }
  }

  /**
   * `killed` alone only reflects an explicit kill we issued, so a grok that crashed or
   * exited on its own still reported as running. Turns were then written into a closed
   * stdin and hung forever, and every later message 409'd for the life of the bridge.
   */
  get running() {
    const p = this.proc;
    if (!p || p.killed) return false;
    if (p.exitCode !== null || p.signalCode !== null) return false;
    return Boolean(p.stdin && p.stdin.writable);
  }

  _send(obj) {
    if (!this.running) throw new Error("grok agent is not running");
    this.proc.stdin.write(JSON.stringify(obj) + "\n");
  }

  _request(method, params, timeoutMs = 0) {
    const id = this._nextId++;
    this._send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => {
      // A prompt is a whole turn and can legitimately run for a long time, so it passes
      // no timeout and is bounded by the stall watchdog instead. Handshake calls do get
      // one: a grok that accepts stdin but never answers used to wedge session creation.
      const timer = timeoutMs
        ? setTimeout(() => {
            this._pending.delete(id);
            reject(new Error(`grok did not answer ${method} within ${Math.round(timeoutMs / 1000)}s`));
          }, timeoutMs)
        : null;
      if (timer?.unref) timer.unref();
      this._pending.set(id, {
        resolve: (v) => { if (timer) clearTimeout(timer); resolve(v); },
        reject: (e) => { if (timer) clearTimeout(timer); reject(e); },
      });
    });
  }

  _clearStallTimer() {
    if (this._stallTimer) { clearInterval(this._stallTimer); this._stallTimer = null; }
  }

  /** Kill a turn that has produced no protocol traffic at all for STALL_TIMEOUT. */
  _startStallTimer() {
    this._clearStallTimer();
    const timer = setInterval(() => {
      // Waiting on the user is not a stall, however long it takes.
      if (this._permissions.size || this._plans.size) return;
      if (Date.now() - this.lastActivity < STALL_TIMEOUT) return;
      console.error(`[acp] no activity for ${Math.round(STALL_TIMEOUT / 60000)}m, stopping a wedged grok`);
      this._clearStallTimer();
      this.stop();   // _failPending unwinds prompt(), which releases the turn and the caffeinate hold
    }, 60000);
    if (timer.unref) timer.unref();
    this._stallTimer = timer;
  }

  _onLine(line) {
    const t = line.trim();
    if (!t) return;
    let msg;
    try { msg = JSON.parse(t); } catch { return; }

    if (msg.method && msg.id !== undefined) return this._onServerRequest(msg);
    if (msg.method) return this._onNotification(msg);
    if (msg.id !== undefined) {
      const p = this._pending.get(msg.id);
      if (p) {
        this._pending.delete(msg.id);
        msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
      }
    }
  }

  _onServerRequest(msg) {
    if (msg.method === "session/request_permission") {
      const { toolCall, options } = msg.params || {};
      const meta = toolCall?._meta?.["x.ai/tool"] || {};
      this._permissions.set(this._tag(msg.id), msg.id);
      this.onEvent({
        kind: "permission_request",
        requestId: this._tag(msg.id),
        toolCallId: toolCall?.toolCallId,
        title: toolCall?.title,
        tool: meta.name || toolCall?.kind,
        command: toolCall?.rawInput?.command,
        readOnly: meta.read_only,
        options: (options || []).map((o) => ({ optionId: o.optionId, name: o.name, kind: o.kind })),
      });
      // Intentionally no response yet — the phone answers via resolvePermission().
    } else if (msg.method === "_x.ai/exit_plan_mode") {
      // Grok finished planning and wants to proceed — forward the plan for review.
      this._plans.set(this._tag(msg.id), msg.id);
      this.onEvent({
        kind: "plan_review",
        requestId: this._tag(msg.id),
        toolCallId: msg.params?.toolCallId,
        planContent: msg.params?.planContent || "",
      });
    } else {
      // Acking blind is the safest default, but doing it silently meant a new
      // server-to-client method (hooks, plugin callbacks) would take an unintended
      // default with no diagnostic anywhere. Warn once per method.
      if (!this._unhandled.has(msg.method)) {
        this._unhandled.add(msg.method);
        console.error(`[acp] acking unhandled grok request method: ${msg.method}`);
      }
      this._send({ jsonrpc: "2.0", id: msg.id, result: {} }); // ack unsupported client methods
    }
  }

  /** Approve or reject a plan. Approving exits plan mode so the next turn executes. */
  resolvePlan(requestId, approved) {
    const gid = this._plans.get(String(requestId));
    if (gid === undefined) return false;
    this._plans.delete(String(requestId));
    this._send({ jsonrpc: "2.0", id: gid, result: { approved: Boolean(approved) } });
    if (approved) this.setMode("default");
    this.onEvent({ kind: "plan_resolved", requestId: String(requestId), approved: Boolean(approved) });
    return true;
  }

  /** Answer a pending permission request. optionId null => cancel. */
  resolvePermission(requestId, optionId) {
    const gid = this._permissions.get(String(requestId));
    if (gid === undefined) return false;
    this._permissions.delete(String(requestId));
    const outcome = optionId ? { outcome: "selected", optionId } : { outcome: "cancelled" };
    this._send({ jsonrpc: "2.0", id: gid, result: { outcome } });
    // Tell all clients it's resolved so the approval card collapses everywhere.
    this.onEvent({ kind: "permission_resolved", requestId: String(requestId), optionId: optionId ?? null });
    return true;
  }

  _onNotification(msg) {
    // Any traffic at all counts as progress for the stall watchdog.
    this.lastActivity = Date.now();
    const u = msg.params?.update;
    if (!u) {
      // grok 1.0.0 emits a family of _x.ai/* notifications that carry no `update`
      // (models/update, queue/changed, mcp/servers_updated, sessions/changed…). None
      // needs handling today, but silence here is how a future one goes unnoticed.
      this._noteUnhandled(msg.method);
      return;
    }
    if (this._replaying) return;   // session/load echoing history we already have
    const text = (c) => c?.text ?? (typeof c === "string" ? c : "");
    switch (u.sessionUpdate) {
      case "agent_message_chunk": this.onEvent({ kind: "text", text: text(u.content) }); break;
      case "agent_thought_chunk": this.onEvent({ kind: "thought", text: text(u.content) }); break;
      case "tool_call":
        this.onEvent({
          kind: "tool_call",
          id: u.toolCallId,
          tool: u._meta?.["x.ai/tool"]?.name || u.title,
          title: u.title,
          command: u.rawInput?.command,
          readOnly: u._meta?.["x.ai/tool"]?.read_only,
        });
        break;
      case "tool_call_update": {
        // Grok's edit tools attach a structured before/after diff in the update content.
        const items = Array.isArray(u.content) ? u.content : [];
        const d = items.find((c) => c?.type === "diff");
        // …and shell/read tools attach their actual output as text content. Without
        // this the phone shows a bare ✗ with no way to see why a command failed.
        const texts = items
          .filter((c) => c?.type === "content" && c.content?.type === "text")
          .map((c) => c.content.text)
          .filter(Boolean);
        let output = texts.join("\n") || u.rawOutput?.stdout || u.rawOutput?.stderr || "";
        if (output.length > OUTPUT_LIMIT) {
          output = output.slice(0, OUTPUT_LIMIT) + `\n… (truncated, ${output.length} chars total)`;
        }
        this.onEvent({
          kind: "tool_update", id: u.toolCallId, status: u.status, title: u.title,
          exitCode: u.rawOutput?.exit_code,
          output: output || undefined,
          diff: d ? { path: d.path, oldText: d.oldText ?? "", newText: d.newText ?? "" } : undefined,
        });
        break;
      }
      case "plan":
        this.onEvent({ kind: "plan", entries: u.entries });
        break;
      case "current_mode_update":
        this.onEvent({ kind: "mode", mode: u.currentModeId });
        break;
      case "available_commands_update":
        // grok advertises its slash commands (built-ins + skills) here; surface them
        // so the phone can offer a "/" command palette like the terminal TUI.
        this._adoptCommands(u.availableCommands || []);
        break;
      case "auto_compact_completed":
        // Fires for grok's own threshold compaction as well as an explicit /compact.
        // It is a marker, not a reply: nothing else in the stream says the window shrank.
        this.onEvent({
          kind: "compacted",
          tokensBefore: u.tokens_before ?? u.tokensBefore ?? null,
          tokensAfter: u.tokens_after ?? u.tokensAfter ?? null,
        });
        break;
      case "user_message_chunk":
        break;   // our own prompt echoed back
      default:
        this._noteUnhandled(`${msg.method}:${u.sessionUpdate}`);
    }
  }

  /** Warn once per unrecognised notification, so new grok surface is visible in the log. */
  _noteUnhandled(key) {
    if (!key || this._unhandled.has(key)) return;
    this._unhandled.add(key);
    console.error(`[acp] unhandled grok notification: ${key}`);
  }

  /**
   * Normalise grok's command roster and decide how each one should be routed.
   *
   * grok 0.2.x really did run its built-ins only in the TUI. grok 1.0.0 executes them
   * over ACP: /workflow, /goal and /feedback all return real text, and /compact
   * compacts in place. Only /context is still genuinely inert.
   *
   * Two fields are emitted because the App Store build cannot be patched. `action` is
   * explicit and is what current clients read. `scope` stays legacy-compatible: older
   * clients derive routing from it, treating anything non-builtin as "send to grok",
   * which is exactly what the newly-working commands need.
   */
  _adoptCommands(raw) {
    const list = (raw || []).map((c) => ({
      name: String(c.name || "").replace(/^\//, ""),
      description: c.description || "",
      hint: c.input?.hint || "",
      kind: c._meta?.scope || "builtin",     // grok's own classification, unmodified
    })).filter((c) => c.name);

    // Gate on the roster itself rather than a version string: these three only exist
    // on builds that execute their built-ins over ACP.
    const names = new Set(list.map((c) => c.name));
    const executesBuiltins = ["workflow", "goal", "deep-research"].some((n) => names.has(n));

    const cmds = list.map((c) => {
      const out = { ...c, scope: c.kind, routing: "send", costly: false };
      if (c.kind !== "builtin") return out;                 // skills always ran as a normal turn
      if (!executesBuiltins) {
        // Legacy grok: only the three the app can perform itself are usable.
        out.routing = c.name === "context" || c.name === "session-info" ? "details"
          : c.name === "always-approve" ? "auto-approve"
          : "hidden";
        return out;
      }
      switch (c.name) {
        case "context":
          out.routing = "details";        // measured: still emits nothing at all
          break;
        case "session-info":
          out.routing = "details";        // works, but duplicates the details sheet
          break;
        case "always-approve":
          // NEVER forward this. The bridge owns the approval loop; flipping grok's own
          // mode would stop session/request_permission arriving and silently delete the
          // phone's approval cards while the toggle still read "Ask each time".
          out.routing = "auto-approve";
          break;
        case "deep-research":
        case "loop":
          // Real, and expensive: a bare /loop measured ~52k tokens and outlives the
          // session. Offer it only where the client can warn first.
          out.routing = "send";
          out.costly = true;
          out.scope = "builtin";         // older clients hide it, which is the safe default
          return out;
        default:
          out.routing = "send";
          out.scope = "command";         // routes to "send" on clients that predate `action`
          return out;
      }
      out.scope = "builtin";
      return out;
    });

    this.availableCommands = cmds;
    this.onEvent({ kind: "commands", commands: cmds });
  }

  async prompt(text) {
    this.lastActivity = Date.now();
    this._startStallTimer();
    let result;
    try {
      result = await this._request("session/prompt", {
        sessionId: this.grokSessionId,
        prompt: [{ type: "text", text }],
      });
    } finally {
      this._clearStallTimer();
    }
    this.lastActivity = Date.now();
    // grok reports token usage for the turn in the result _meta — surface it so the
    // bridge can accumulate per-session + overall usage.
    const meta = result?._meta || {};
    const usage = meta.usage || null;
    return {
      stopReason: result?.stopReason || "end_turn",
      usage,   // { inputTokens, outputTokens, totalTokens, cachedReadTokens, reasoningTokens, costUsdTicks, modelCalls, apiDurationMs, numTurns }
      contextTokens: await this._contextUsed(usage),
      contextWindow: this.contextWindow || null,
      modelId: meta.modelId || this.currentModelId || this.model || null,
    };
  }

  /**
   * How much of the context window the conversation now occupies.
   *
   * `usage.inputTokens` is the turn's BILLED input, summed over `usage.modelCalls`, so
   * a tool-heavy turn multiplies it and the meter runs ahead of reality. grok exposes
   * the real footprint via _x.ai/session/info, at zero tokens and zero model calls, and
   * it is accurate once a turn has run on this process. Fall back to the billed figure
   * on older grok, where the method does not exist.
   */
  async _contextUsed(usage) {
    try {
      const info = await this._request("_x.ai/session/info", { sessionId: this.grokSessionId }, 10000);
      const ctx = info?.result?.context || info?.context;   // the payload is double-wrapped
      if (Number.isFinite(ctx?.used)) {
        if (Number.isFinite(ctx?.total) && ctx.total > 0) this.contextWindow = ctx.total;
        return ctx.used;
      }
    } catch { /* older grok, or the session went away — fall through */ }
    return usage?.inputTokens ?? null;
  }

  cancel() {
    try { this._send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: this.grokSessionId } }); }
    catch { /* ignore */ }
  }

  stop() {
    this._clearStallTimer();
    try { this.proc?.kill(); } catch { /* ignore */ }
    this._failPending(new Error("grok agent stopped"));
  }

  /**
   * Unwind everything in flight so callers stop hanging.
   *
   * The permission and plan maps used to be left behind, so an approval card outlived
   * the process that asked for it: it persisted into the transcript, replayed on every
   * reconnect, and 409'd on every tap, with nothing to tell the phone it was dead.
   */
  _failPending(err) {
    for (const [, pending] of this._pending) {
      try { pending.reject(err); } catch { /* already settled */ }
    }
    this._pending.clear();

    for (const requestId of this._permissions.keys()) {
      try { this.onEvent({ kind: "permission_resolved", requestId, optionId: null, abandoned: true }); }
      catch { /* best effort */ }
    }
    this._permissions.clear();
    for (const requestId of this._plans.keys()) {
      try { this.onEvent({ kind: "plan_resolved", requestId, approved: false, abandoned: true }); }
      catch { /* best effort */ }
    }
    this._plans.clear();
  }
}
