// Phase 2 (after a bridge restart): reopen the session by id, confirm its history
// replays (can be followed), and that a new turn resumes context via session/load.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const H = { authorization: "Bearer " + token, "content-type": "application/json" };
const id = process.argv[2];

const info = await (await fetch(base + "/api/sessions/" + id, { headers: H })).json();
console.log("REOPENED:", info.id ? `title="${info.title}" turns=${info.turnCount} grokResume=${!!info.grokSessionId ? "n/a" : ""}` : "MISSING");

// Replay history to confirm the past conversation is followable.
let replayedUser = false;
let answer = "";
let capture = false;
const ctrl = new AbortController();
const done = (async () => {
  const res = await fetch(base + "/api/sessions/" + id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = "";
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const f = buf.slice(0, i); buf = buf.slice(i + 2);
      const d = f.split("\n").find((l) => l.startsWith("data: ")); if (!d) continue;
      const ev = JSON.parse(d.slice(6));
      if (ev.kind === "turn_start" && /remember/i.test(ev.text || "")) replayedUser = true;
      if (ev.kind === "text" && capture) answer += ev.text;
      if (ev.kind === "turn_complete" && capture) { ctrl.abort(); return; }
    }
  }
})().catch(() => {});

await new Promise((r) => setTimeout(r, 1200)); // let history replay
console.log("HISTORY REPLAY:", replayedUser ? "PASS ✓ (old conversation followable)" : "FAIL ✗");

capture = true;
await fetch(base + "/api/sessions/" + id + "/messages", { method: "POST", headers: H, body: JSON.stringify({ text: "What secret number did I ask you to remember? Reply with only the number." }) });
await done;
console.log("CONTEXT RESUME:", /77/.test(answer) ? "PASS ✓ (remembered 77 after restart)" : `FAIL ✗ (got "${answer.trim()}")`);
process.exit(0);
