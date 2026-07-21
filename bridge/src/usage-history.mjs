// Day-by-day usage rollups, so "what has this cost me?" has an answer with a shape
// to it rather than one lifetime number that only ever goes up.
//
// Deliberately a rollup and not a per-turn log: a record per turn would grow without
// bound and carry prompts around with it. A day holds counters only — no text, no
// paths, nothing about what the work was.

import { existsSync, readFileSync, writeFileSync } from "node:fs";

const KEEP_DAYS = 120;

function emptyDay() {
  return {
    turns: 0, inputTokens: 0, outputTokens: 0, reasoningTokens: 0,
    cachedReadTokens: 0, totalTokens: 0, costUsdTicks: 0, apiDurationMs: 0,
  };
}

/** Local calendar day (YYYY-MM-DD). Deliberately local, not UTC: the user reads this
 *  against their own day, and a turn at 9pm belongs to the day they ran it. */
function today() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export class UsageHistory {
  constructor(path) {
    this._path = path || null;
    this._days = new Map();     // "YYYY-MM-DD" -> counters
    this._dirty = false;
    this._load();
    // Batch writes: a busy session reports usage every turn, and this is a rollup —
    // losing at most 30s of counters to a crash is a fine trade for not doing a
    // synchronous JSON write in the middle of every turn's completion path.
    if (this._path) {
      const timer = setInterval(() => this.flush(), 30_000);
      timer.unref?.();
    }
  }

  /** Fold one turn's reported usage into today's bucket. */
  record(usage) {
    if (!usage || typeof usage !== "object") return;
    const key = today();
    const day = this._days.get(key) || emptyDay();
    day.turns += 1;
    day.inputTokens += usage.inputTokens || 0;
    day.outputTokens += usage.outputTokens || 0;
    day.reasoningTokens += usage.reasoningTokens || 0;
    day.cachedReadTokens += usage.cachedReadTokens || 0;
    day.totalTokens += usage.totalTokens || 0;
    day.costUsdTicks += usage.costUsdTicks || 0;
    day.apiDurationMs += usage.apiDurationMs || 0;
    this._days.set(key, day);
    this._dirty = true;
  }

  /** Most recent `days` calendar days, oldest first, with gaps filled in as zeroes
   *  so a chart doesn't silently close up the days nothing ran. */
  list(days = 30) {
    const n = Math.max(1, Math.min(Number(days) || 30, KEEP_DAYS));
    const out = [];
    const cursor = new Date();
    for (let i = n - 1; i >= 0; i--) {
      const d = new Date(cursor);
      d.setDate(d.getDate() - i);
      const p = (x) => String(x).padStart(2, "0");
      const key = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
      out.push({ date: key, ...(this._days.get(key) || emptyDay()) });
    }
    return out;
  }

  flush() {
    if (!this._dirty || !this._path) return;
    this._prune();
    try {
      writeFileSync(this._path, JSON.stringify({ days: Object.fromEntries(this._days) }));
      this._dirty = false;
    } catch { /* best-effort */ }
  }

  _prune() {
    if (this._days.size <= KEEP_DAYS) return;
    const keys = [...this._days.keys()].sort();
    for (const k of keys.slice(0, keys.length - KEEP_DAYS)) this._days.delete(k);
  }

  _load() {
    if (!this._path || !existsSync(this._path)) return;
    try {
      const parsed = JSON.parse(readFileSync(this._path, "utf8"));
      for (const [k, v] of Object.entries(parsed?.days || {})) {
        this._days.set(k, { ...emptyDay(), ...v });
      }
    } catch { /* ignore a corrupt file */ }
  }
}
