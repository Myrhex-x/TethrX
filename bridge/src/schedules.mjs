// Scheduled tasks: "every weekday at 9, pull main and run the tests".
//
// Each schedule belongs to a session (whose cwd/effort/approval settings it
// reuses) and fires on the BRIDGE MACHINE'S local clock — "9am where your
// computer is", which is what people mean. Results arrive like any other turn:
// a push when it finishes, an approval push if grok needs one.

import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

export class ScheduleStore {
  constructor(persistPath) {
    this._path = persistPath;
    this._byId = new Map();
    this._load();
  }

  _load() {
    if (!this._path || !existsSync(this._path)) return;
    try {
      for (const s of JSON.parse(readFileSync(this._path, "utf8"))) {
        if (s && s.id) this._byId.set(s.id, s);
      }
    } catch { /* ignore a corrupt file */ }
  }

  save() {
    if (!this._path) return;
    try { writeFileSync(this._path, JSON.stringify([...this._byId.values()], null, 2)); }
    catch { /* best-effort */ }
  }

  list() { return [...this._byId.values()]; }
  get(id) { return this._byId.get(id) || null; }

  /** Validate + create. Returns the schedule, or a string describing what's wrong. */
  create({ sessionId, prompt, hour, minute, weekdays, enabled }) {
    const p = String(prompt || "").trim();
    if (!sessionId) return "missing sessionId";
    if (!p) return "missing prompt";
    if (p.length > 4000) return "prompt too long";
    if (!Number.isInteger(hour) || hour < 0 || hour > 23) return "hour must be 0-23";
    if (!Number.isInteger(minute) || minute < 0 || minute > 59) return "minute must be 0-59";
    const days = Array.isArray(weekdays) ? weekdays.filter((d) => Number.isInteger(d) && d >= 0 && d <= 6) : [];
    const s = {
      id: randomUUID(), sessionId, prompt: p, hour, minute,
      weekdays: [...new Set(days)].sort(),          // 0=Sunday … 6=Saturday; empty = every day
      enabled: enabled !== false,
      createdAt: new Date().toISOString(),
      lastRunAt: 0,
    };
    this._byId.set(s.id, s);
    this.save();
    return s;
  }

  update(id, patch) {
    const s = this._byId.get(id);
    if (!s) return null;
    if (typeof patch.enabled === "boolean") s.enabled = patch.enabled;
    if (typeof patch.prompt === "string" && patch.prompt.trim()) s.prompt = patch.prompt.trim().slice(0, 4000);
    if (Number.isInteger(patch.hour) && patch.hour >= 0 && patch.hour <= 23) s.hour = patch.hour;
    if (Number.isInteger(patch.minute) && patch.minute >= 0 && patch.minute <= 59) s.minute = patch.minute;
    if (Array.isArray(patch.weekdays)) {
      s.weekdays = [...new Set(patch.weekdays.filter((d) => Number.isInteger(d) && d >= 0 && d <= 6))].sort();
    }
    this.save();
    return s;
  }

  delete(id) {
    const had = this._byId.delete(id);
    if (had) this.save();
    return had;
  }

  removeForSession(sessionId) {
    let changed = false;
    for (const [id, s] of this._byId) {
      if (s.sessionId === sessionId) { this._byId.delete(id); changed = true; }
    }
    if (changed) this.save();
  }
}

/**
 * Fire due schedules. Checks every 20s; a schedule fires at most once per due
 * minute (the persisted lastRunAt also guards against a restart double-fire).
 * `fire(session, schedule)` starts the turn; `onSkip(session, schedule, why)`
 * lets the server push "skipped" alerts.
 */
export function startScheduler({ schedules, sessions, fire, onSkip }) {
  const timer = setInterval(() => {
    const now = new Date();
    for (const s of schedules.list()) {
      if (!s.enabled) continue;
      if (s.weekdays.length && !s.weekdays.includes(now.getDay())) continue;
      if (now.getHours() !== s.hour || now.getMinutes() !== s.minute) continue;
      if (Date.now() - (s.lastRunAt || 0) < 90_000) continue;   // already fired this minute
      s.lastRunAt = Date.now();
      schedules.save();
      const session = sessions.get(s.sessionId);
      if (!session) {                       // its session was deleted — disable, don't error forever
        s.enabled = false;
        schedules.save();
        continue;
      }
      if (session.status === "running") {
        onSkip?.(session, s, "a turn was already running");
        continue;
      }
      try { fire(session, s); } catch { /* the turn's own error path reports */ }
    }
  }, 20_000);
  timer.unref?.();
  return timer;
}
