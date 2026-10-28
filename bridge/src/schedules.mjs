// Scheduled tasks: "every weekday at 9, pull main and run the tests".
//
// Each schedule belongs to a session (whose cwd/effort/approval settings it
// reuses) and fires on the BRIDGE MACHINE'S local clock — "9am where your
// computer is", which is what people mean. Results arrive like any other turn:
// a push when it finishes, an approval push if grok needs one.

import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync } from "node:fs";
import { writeAtomic } from "./sessions.mjs";

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
    } catch (e) {
      // Loading empty and saving over it was how one torn write erased every schedule.
      console.error(`[schedules] unreadable schedules file: ${e.message}`);
      try { renameSync(this._path, `${this._path}.corrupt`); } catch { /* best-effort */ }
    }
  }

  save() {
    if (!this._path) return;
    try { writeAtomic(this._path, JSON.stringify([...this._byId.values()], null, 2), 0o644); }
    catch { /* best-effort */ }
  }

  list() { return [...this._byId.values()]; }
  get(id) { return this._byId.get(id) || null; }

  /** Validate + create. Returns the schedule, or a string describing what's wrong. */
  create({ sessionId, prompt, hour, minute, weekdays, enabled }) {
    const badDays = invalidWeekdays(weekdays);
    if (badDays) return badDays;
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

  /** Returns the schedule, null when there is none, or a string describing what's wrong. */
  update(id, patch) {
    const s = this._byId.get(id);
    if (!s) return null;
    const badDays = invalidWeekdays(patch.weekdays);
    if (badDays) return badDays;
    const timing = () => `${s.hour}:${s.minute}:${s.weekdays}`;
    const was = timing();
    if (typeof patch.enabled === "boolean") {
      // Switching one back on after its time has passed is not a missed run either.
      if (patch.enabled && !s.enabled) s.retimedAt = Date.now();
      s.enabled = patch.enabled;
    }
    if (typeof patch.prompt === "string" && patch.prompt.trim()) s.prompt = patch.prompt.trim().slice(0, 4000);
    if (Number.isInteger(patch.hour) && patch.hour >= 0 && patch.hour <= 23) s.hour = patch.hour;
    if (Number.isInteger(patch.minute) && patch.minute >= 0 && patch.minute <= 59) s.minute = patch.minute;
    if (Array.isArray(patch.weekdays)) {
      s.weekdays = [...new Set(patch.weekdays.filter((d) => Number.isInteger(d) && d >= 0 && d <= 6))].sort();
    }
    // Moving a schedule to a time that already passed today must not read as a
    // missed run: without this, editing 9am to 8am at noon pushed "skipped" the
    // instant you saved the edit.
    if (timing() !== was) s.retimedAt = Date.now();
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

// How late a run may be and still be worth starting. Node timers do not tick while
// the Mac is asleep, so the tick that should have landed at 9am arrives whenever the
// lid opens. Inside this window we run it anyway; past it the user is told it was
// missed rather than ambushed by a task from hours ago.
const GRACE_MS = 15 * 60 * 1000;

const pad = (n) => String(n).padStart(2, "0");

/** Local "YYYY-MM-DDTHH:mm" stamp: the identity of one occurrence of a schedule. */
function runKey(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * The latest moment this schedule was due at or before `now`, or null if it has
 * never come due. Walking back day by day (rather than testing today's weekday)
 * is what lets a run survive being noticed late.
 *
 * Each day's moment is built from that day's own date. Shifting one Date back a
 * day at a time carried a time the clocks skipped (02:30 on the spring-forward
 * night becomes 03:30) into the day before, which made yesterday's 02:30 run look
 * missed and pushed a false "skipped" notice.
 */
function lastDue(s, now) {
  for (let back = 0; back <= 8; back++) {                   // 0=Sunday … 6=Saturday
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back, s.hour, s.minute, 0, 0);
    if (d.getTime() > now.getTime()) continue;
    if (!s.weekdays.length || s.weekdays.includes(d.getDay())) return d;
  }
  return null;
}

/** Weekdays must be whole numbers 0-6. Anything else used to be dropped quietly, and
 *  an empty list means "every day": [9] became a schedule that ran daily. */
function invalidWeekdays(weekdays) {
  if (weekdays === undefined || weekdays === null) return null;
  if (!Array.isArray(weekdays)) return "weekdays must be a list of days 0-6";
  return weekdays.every((d) => Number.isInteger(d) && d >= 0 && d <= 6) ? null : "weekdays must be 0-6 (0 is Sunday)";
}

/** Occurrences before the schedule existed (or before its time was last moved) are not misses. */
function notBefore(s) {
  const created = Date.parse(s.createdAt || "");
  return Math.max(Number.isFinite(created) ? created : 0, s.retimedAt || 0);
}

/** Has this exact occurrence already been dealt with, by firing or by reporting it missed? */
function settled(s, key, due) {
  if (s.lastRunKey) return s.lastRunKey === key;
  return (s.lastRunAt || 0) >= due.getTime();   // records written before lastRunKey existed
}

/**
 * Fire due schedules. Checks every 20s and compares the clock against the most
 * recent due moment rather than the current minute, because an exact hh:mm match
 * needs the machine awake for that one minute: close the lid at 23:00 and the 9am
 * weekday task was silently never run. A run more than GRACE_MS late is reported
 * through `onSkip` instead. Each occurrence is stamped with its local wall-clock
 * `lastRunKey`, so the hour that repeats on the autumn DST change cannot fire twice
 * (the persisted lastRunAt also guards against a restart double-fire).
 * `fire(session, schedule)` starts the turn; `onSkip(session, schedule, why)`
 * lets the server push "skipped" alerts.
 *
 * @param now injectable clock, for tests
 */
export function startScheduler({ schedules, sessions, fire, onSkip, now = () => new Date() }) {
  const tick = () => {
    const at = now();
    for (const s of schedules.list()) {
      if (!s.enabled) continue;
      const due = lastDue(s, at);
      if (!due) continue;
      if (due.getTime() < notBefore(s)) continue;
      const key = runKey(due);
      if (settled(s, key, due)) continue;
      if (at.getTime() - (s.lastRunAt || 0) < 90_000) continue;   // already fired this minute

      const session = sessions.get(s.sessionId);
      if (!session) {                       // its session was deleted — disable, don't error forever
        s.enabled = false;
        schedules.save();
        continue;
      }
      // Stamped before we decide what to do with it: a miss left unstamped would be
      // re-reported on every tick for the rest of the day. Only a real run touches
      // lastRunAt, or the tick that reports last night's miss at 08:59 would put the
      // 90 second guard in front of today's 09:00 run.
      s.lastRunKey = key;
      schedules.save();
      if (at.getTime() - due.getTime() > GRACE_MS) {
        onSkip?.(session, s, `the computer was not awake at ${pad(due.getHours())}:${pad(due.getMinutes())}`);
        continue;
      }
      if (session.status === "running") {
        onSkip?.(session, s, "a turn was already running");
        continue;
      }
      s.lastRunAt = at.getTime();
      schedules.save();
      try { fire(session, s); } catch { /* the turn's own error path reports */ }
    }
  };
  const timer = setInterval(tick, 20_000);
  timer.unref?.();
  return timer;
}
