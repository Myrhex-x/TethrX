// In-memory session registry + per-session SSE event hub.
//
// Each Session owns a Grok conversation (identified by a UUID we pass to `grok -s`),
// a ring buffer of emitted events (so a phone that reconnects can replay what it
// missed via Last-Event-ID), and the set of live SSE subscribers.

import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";

const HISTORY_LIMIT = 5000;

/** Zeroed usage counters. `contextTokens`/`contextWindow` describe the latest
 *  turn's footprint vs the model's window; the rest are lifetime totals. */
function emptyUsage() {
  return {
    turns: 0,
    inputTokens: 0, outputTokens: 0, reasoningTokens: 0, cachedReadTokens: 0, totalTokens: 0,
    costUsdTicks: 0, apiDurationMs: 0,
    contextTokens: 0, contextWindow: 0, lastModelId: "",
  };
}

function normalizeUsage(u) {
  return { ...emptyUsage(), ...(u && typeof u === "object" ? u : {}) };
}

const EDITED_PATHS_LIMIT = 200;

class Session {
  constructor({ id, cwd, model, title, transport, effort, createdAt, turnCount, grokSessionId, planMode, autoApprove, usage, folder, seedContext, queue, editedPaths, commands }) {
    this.id = id || randomUUID();        // valid v4 UUID — required by `grok -s`
    this.cwd = cwd;
    this.model = model;
    this.effort = effort;
    this.title = title || "New session";
    this.folder = folder || "";          // optional grouping label for the phone's session list
    this.transport = transport || "acp"; // "acp" | "headless"
    this.planMode = planMode || false;
    this.autoApprove = autoApprove || false;    // "always allow" — auto-approve tool permissions
    this.grokSessionId = grokSessionId || null; // grok's ACP sessionId, for session/load resume
    this.createdAt = createdAt || new Date().toISOString();
    this.seedContext = seedContext || null;   // handoff summary from a compacted session; consumed by the first turn
    this.status = "idle";                // "idle" | "running"
    this.turnCount = turnCount || 0;
    this.usage = normalizeUsage(usage);  // token/cost usage, accumulated + persisted
    // Follow-ups waiting for the running turn to finish. This lives on the BRIDGE,
    // not the phone: queueing three instructions and then locking your phone is the
    // whole point, and a queue held in the app's memory dies with the app.
    this.queue = Array.isArray(queue) ? queue.filter((q) => q && typeof q.text === "string") : [];
    // Absolute paths of files grok actually edited (from tool diff events). Sessions
    // usually START in the home directory but WORK somewhere deeper — this is how the
    // git review finds the repo grok really changed instead of shrugging at ~.
    this.editedPaths = Array.isArray(editedPaths)
      ? editedPaths.filter((p) => typeof p === "string").slice(-EDITED_PATHS_LIMIT)
      : [];
    // Snapshot of grok's advertised slash commands, kept across ACP restarts so the
    // phone's "/" palette works even before the next turn spins the process back up.
    this.commands = Array.isArray(commands) ? commands : [];

    this.historyPath = null;             // set by the store; where events are persisted
    this.acp = null;                     // AcpSession (lazy, set by the server for ACP sessions)
    this._events = [];                   // [{ id, event }]
    this._nextEventId = 0;
    this._subscribers = new Set();       // Set<http.ServerResponse>
    this._abort = null;                  // AbortController for a running headless turn
  }

  toJSON() {
    return {
      id: this.id,
      title: this.title,
      folder: this.folder || "",
      cwd: this.cwd,
      model: this.model,
      transport: this.transport,
      planMode: this.planMode,
      effort: this.effort || "",
      autoApprove: this.autoApprove,
      status: this.status,
      turnCount: this.turnCount,
      createdAt: this.createdAt,
      lastEventId: this._nextEventId,
      usage: this.usage,
      queue: this.queue,
      // Present only until the first turn consumes it — the app shows a
      // "carries a summary" card so a compacted session doesn't look amnesiac.
      seedContext: this.seedContext || undefined,
    };
  }

  // --- follow-up queue ----------------------------------------------------

  /** Add a follow-up. `source` is for the app's own labelling ("phone", "reply",
   *  "share"), never sent to grok. */
  enqueue(text, source = "phone") {
    const t = String(text || "").trim();
    if (!t) return null;
    const item = { id: randomUUID(), text: t, source, at: new Date().toISOString() };
    this.queue.push(item);
    return item;
  }

  dequeue() {
    return this.queue.shift() || null;
  }

  removeQueued(itemId) {
    const before = this.queue.length;
    this.queue = this.queue.filter((q) => q.id !== itemId);
    return this.queue.length !== before;
  }

  /** Remember a file grok edited (deduped, newest kept, capped). */
  noteEdit(path) {
    if (typeof path !== "string" || !path.startsWith("/")) return;
    const i = this.editedPaths.indexOf(path);
    if (i !== -1) this.editedPaths.splice(i, 1);
    this.editedPaths.push(path);
    if (this.editedPaths.length > EDITED_PATHS_LIMIT) this.editedPaths.shift();
  }

  /** Fold one turn's grok-reported usage into the session totals. */
  addUsage({ usage, contextTokens, contextWindow, modelId } = {}) {
    const u = this.usage;
    if (usage && typeof usage === "object") {
      u.turns += 1;
      u.inputTokens += usage.inputTokens || 0;
      u.outputTokens += usage.outputTokens || 0;
      u.reasoningTokens += usage.reasoningTokens || 0;
      u.cachedReadTokens += usage.cachedReadTokens || 0;
      u.totalTokens += usage.totalTokens || 0;
      u.costUsdTicks += usage.costUsdTicks || 0;
      u.apiDurationMs += usage.apiDurationMs || 0;
    }
    if (contextTokens != null) u.contextTokens = contextTokens;
    if (contextWindow) u.contextWindow = contextWindow;
    if (modelId) u.lastModelId = modelId;
    return u;
  }

  /** Durable metadata, persisted across bridge restarts (no live/transient state). */
  toMetadata() {
    return {
      id: this.id, cwd: this.cwd, model: this.model, effort: this.effort,
      transport: this.transport, title: this.title, folder: this.folder || "", planMode: this.planMode,
      autoApprove: this.autoApprove, grokSessionId: this.grokSessionId,
      createdAt: this.createdAt, turnCount: this.turnCount, usage: this.usage,
      seedContext: this.seedContext, queue: this.queue,
      editedPaths: this.editedPaths, commands: this.commands,
    };
  }

  /** Persist the event history so a reopened session shows its full conversation. */
  saveHistory() {
    if (!this.historyPath) return;
    try { writeFileSync(this.historyPath, JSON.stringify(this._events)); } catch { /* best-effort */ }
  }

  loadHistory() {
    if (!this.historyPath || !existsSync(this.historyPath)) return;
    try {
      const events = JSON.parse(readFileSync(this.historyPath, "utf8"));
      if (Array.isArray(events) && events.length) {
        this._events = events;
        this._nextEventId = events[events.length - 1].id || 0;
      }
    } catch { /* ignore corrupt history */ }
  }

  // --- event fan-out ------------------------------------------------------

  emit(event) {
    // Every edit flows through here as a tool_update with a diff — the one reliable
    // signal of where grok actually worked, whatever the session's nominal cwd is.
    if (event?.kind === "tool_update" && event.diff?.path) this.noteEdit(event.diff.path);
    const id = ++this._nextEventId;
    const record = { id, event };
    this._events.push(record);
    if (this._events.length > HISTORY_LIMIT) this._events.shift();

    const frame = `id: ${id}\ndata: ${JSON.stringify(event)}\n\n`;
    for (const res of this._subscribers) {
      res.write(frame);
    }
    return id;
  }

  subscribe(res, lastEventId = 0) {
    // Replay anything the client missed since lastEventId.
    for (const { id, event } of this._events) {
      if (id > lastEventId) {
        res.write(`id: ${id}\ndata: ${JSON.stringify(event)}\n\n`);
      }
    }
    this._subscribers.add(res);
    res.on("close", () => this._subscribers.delete(res));
  }

  get subscriberCount() {
    return this._subscribers.size;
  }

  // --- turn lifecycle -----------------------------------------------------

  beginTurn() {
    if (this.status === "running") return null;
    this.status = "running";
    this.turnCount += 1;
    this._abort = new AbortController();
    return this._abort.signal;
  }

  endTurn() {
    this.status = "idle";
    this._abort = null;
  }

  cancel() {
    if (this.acp) {
      this.acp.cancel();
      return true;
    }
    if (this._abort) {
      this._abort.abort();
      return true;
    }
    return false;
  }
}

export class SessionStore {
  constructor(persistPath) {
    this._byId = new Map();
    this._persistPath = persistPath || null;
    this._historyDir = persistPath ? join(dirname(persistPath), "history") : null;
    if (this._historyDir) { try { mkdirSync(this._historyDir, { recursive: true }); } catch { /* ignore */ } }
    this._load();
  }

  _historyPathFor(id) {
    return this._historyDir ? join(this._historyDir, id + ".json") : null;
  }

  create(opts) {
    const session = new Session(opts);
    session.historyPath = this._historyPathFor(session.id);
    this._byId.set(session.id, session);
    this.save();
    return session;
  }

  get(id) {
    return this._byId.get(id) || null;
  }

  list() {
    return [...this._byId.values()]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map((s) => s.toJSON());
  }

  delete(id) {
    const s = this._byId.get(id);
    if (!s) return false;
    if (s.acp) { try { s.acp.stop(); } catch { /* ignore */ } }
    this._byId.delete(id);
    if (s.historyPath) { try { rmSync(s.historyPath, { force: true }); } catch { /* ignore */ } }
    this.save();
    return true;
  }

  rename(id, title) {
    const s = this._byId.get(id);
    if (!s) return false;
    s.title = title;
    this.save();
    return true;
  }

  /** Persist session metadata so the list survives a bridge restart. */
  save() {
    if (!this._persistPath) return;
    try {
      const data = [...this._byId.values()].map((s) => s.toMetadata());
      writeFileSync(this._persistPath, JSON.stringify(data, null, 2));
    } catch { /* best-effort */ }
  }

  _load() {
    if (!this._persistPath || !existsSync(this._persistPath)) return;
    try {
      for (const meta of JSON.parse(readFileSync(this._persistPath, "utf8"))) {
        const s = new Session(meta);   // meta.id restores the original id
        s.historyPath = this._historyPathFor(s.id);
        s.loadHistory();               // restore the conversation so it can be followed
        this._byId.set(s.id, s);
      }
    } catch { /* ignore a corrupt store */ }
  }
}
