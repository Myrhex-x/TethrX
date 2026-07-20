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
import {
  existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync, rmSync, symlinkSync,
  lstatSync, copyFileSync,
} from "node:fs";

const REAL_GROK = join(homedir(), ".grok");
const OUTPUT_LIMIT = 8000;   // cap tool output per update so a chatty build can't flood the phone

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
    try {
      copyFileSync(mirrored, join(REAL_GROK, name));   // real home becomes authoritative again
      rmSync(mirrored, { force: true });               // drop it so we can re-symlink below
    } catch { /* on any doubt, leave it in place rather than lose credentials */ }
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
    this.grokSessionId = null;
    this.contextWindow = null;       // model's max context tokens (from initialize)
    this.currentModelId = null;      // grok's chosen model when we don't pin one
    this.availableCommands = [];     // grok's slash commands (/compact, /context, skills…)
    this.lastActivity = Date.now();
    this._nextId = 1;
    this._pending = new Map();       // our request id -> {resolve, reject}
    this._permissions = new Map();   // permission requestId (string) -> grok's json-rpc id
    this._plans = new Map();         // exit_plan requestId (string) -> grok's json-rpc id
  }

  async start() {
    // `-m` and `--reasoning-effort` are options of `grok agent`, not of the `stdio`
    // subcommand — they must precede `stdio` or grok exits with "unexpected argument".
    const args = ["agent"];
    if (this.model) args.push("-m", this.model);
    if (this.effort) args.push("--reasoning-effort", this.effort);
    args.push("stdio");

    const env = { ...process.env };
    if (this.home) env.HOME = this.home;

    this.proc = spawn(this.grokBin, args, { cwd: this.cwd, stdio: ["pipe", "pipe", "pipe"], env });
    this.proc.stderr.on("data", (d) => console.error("[grok stderr] " + d.toString().trimEnd())); // drain + surface
    this.rl = createInterface({ input: this.proc.stdout });
    this.rl.on("line", (line) => this._onLine(line));
    this.proc.on("close", () => this.onEvent({ kind: "closed" }));
    this.proc.on("error", (e) => this.onEvent({ kind: "error", message: `grok agent failed: ${e.message}` }));

    const init = await this._request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    });
    // Capture the active model's context window so the phone can show a real meter.
    try {
      const ms = init?._meta?.modelState;
      const cur = ms?.availableModels?.find((m) => m.modelId === ms?.currentModelId) || ms?.availableModels?.[0];
      this.contextWindow = cur?._meta?.totalContextTokens || this.contextWindow;
      this.currentModelId = ms?.currentModelId || this.currentModelId;
    } catch { /* usage meter is best-effort */ }

    // Resume prior context if we have a grok sessionId; otherwise start fresh.
    if (this.resumeSessionId) {
      try {
        await this._request("session/load", { sessionId: this.resumeSessionId, cwd: this.cwd, mcpServers: [] });
        this.grokSessionId = this.resumeSessionId;
      } catch {
        const res = await this._request("session/new", { cwd: this.cwd, mcpServers: [] });
        this.grokSessionId = res?.sessionId;
      }
    } else {
      const res = await this._request("session/new", { cwd: this.cwd, mcpServers: [] });
      this.grokSessionId = res?.sessionId;
    }

    if (this.planMode) {
      try { await this._request("session/set_mode", { sessionId: this.grokSessionId, modeId: "plan" }); } catch { /* mode optional */ }
    }
    return this.grokSessionId;
  }

  setMode(modeId) {
    const id = this._nextId++;
    try { this._send({ jsonrpc: "2.0", id, method: "session/set_mode", params: { sessionId: this.grokSessionId, modeId } }); } catch { /* ignore */ }
  }

  get running() { return Boolean(this.proc && !this.proc.killed); }

  _send(obj) { this.proc.stdin.write(JSON.stringify(obj) + "\n"); }

  _request(method, params) {
    const id = this._nextId++;
    this._send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => this._pending.set(id, { resolve, reject }));
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
      this._permissions.set(String(msg.id), msg.id);
      this.onEvent({
        kind: "permission_request",
        requestId: String(msg.id),
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
      this._plans.set(String(msg.id), msg.id);
      this.onEvent({
        kind: "plan_review",
        requestId: String(msg.id),
        toolCallId: msg.params?.toolCallId,
        planContent: msg.params?.planContent || "",
      });
    } else {
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
    const u = msg.params?.update;
    if (!u) return;
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
      case "available_commands_update": {
        // grok advertises its slash commands (built-ins + skills) here; surface them
        // so the phone can offer a "/" command palette like the terminal TUI.
        const cmds = (u.availableCommands || []).map((c) => ({
          name: String(c.name || "").replace(/^\//, ""),
          description: c.description || "",
          hint: c.input?.hint || "",
          scope: c._meta?.scope || "builtin",
        })).filter((c) => c.name);
        this.availableCommands = cmds;
        this.onEvent({ kind: "commands", commands: cmds });
        break;
      }
      // user_message_chunk / x.ai internals -> ignored
    }
  }

  async prompt(text) {
    this.lastActivity = Date.now();
    const result = await this._request("session/prompt", {
      sessionId: this.grokSessionId,
      prompt: [{ type: "text", text }],
    });
    this.lastActivity = Date.now();
    // grok reports token usage for the turn in the result _meta — surface it so the
    // bridge can accumulate per-session + overall usage.
    const meta = result?._meta || {};
    const usage = meta.usage || null;
    return {
      stopReason: result?.stopReason || "end_turn",
      usage,   // { inputTokens, outputTokens, totalTokens, cachedReadTokens, reasoningTokens, costUsdTicks, modelCalls, apiDurationMs, numTurns }
      contextTokens: (usage?.inputTokens ?? meta.inputTokens) ?? null,  // ~current conversation footprint
      contextWindow: this.contextWindow || null,
      modelId: meta.modelId || this.currentModelId || this.model || null,
    };
  }

  cancel() {
    try { this._send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: this.grokSessionId } }); }
    catch { /* ignore */ }
  }

  stop() {
    try { this.proc?.kill(); } catch { /* ignore */ }
  }
}
