// Verify mid-turn cancel actually stops a running ACP turn.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "cancel" }),
})).json();
console.log("SESSION", session.id);

let cancelled = false;
let firstAt = 0;
const ctrl = new AbortController();
const done = (async () => {
  const res = await fetch(base + "/api/sessions/" + session.id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = "";
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 2);
      const dline = frame.split("\n").find((l) => l.startsWith("data: ")); if (!dline) continue;
      const ev = JSON.parse(dline.slice(6));
      // As soon as Grok starts producing output, cancel.
      if ((ev.kind === "text" || ev.kind === "thought") && !cancelled) {
        cancelled = true; firstAt = performance.now();
        await fetch(base + "/api/sessions/" + session.id + "/cancel", { method: "POST", headers: H });
        console.log("→ sent cancel while running");
      }
      if (ev.kind === "turn_complete" || ev.kind === "error") {
        ctrl.abort();
        return { kind: ev.kind, stopReason: ev.stopReason, ms: Math.round(performance.now() - firstAt) };
      }
    }
  }
})().catch(() => null);

await new Promise((r) => setTimeout(r, 400));
await fetch(base + "/api/sessions/" + session.id + "/messages", {
  method: "POST", headers: H,
  body: JSON.stringify({ text: "Write a very long, detailed 800-word essay about the history of the ocean. Take your time and think carefully." }),
});

const result = await done;
console.log("RESULT:", JSON.stringify(result));
console.log("CANCEL:", result && result.ms < 15000 ? `PASS ✓ (turn ended ${result.ms}ms after cancel)` : "FAIL ✗ (did not stop promptly)");
process.exit(0);
