// Verify ACP multi-turn context (the persistent process must remember across turns)
// and that the session is persisted to ~/.grok-remote/sessions.json.

import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "multiturn" }),
})).json();
console.log("SESSION", session.id);

// One persistent stream; resolve a promise each time a turn completes.
let onComplete = null;
let capture = false;
let answer = "";
const ctrl = new AbortController();
(async () => {
  const res = await fetch(base + "/api/sessions/" + session.id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = "";
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 2);
      const dline = frame.split("\n").find((l) => l.startsWith("data: ")); if (!dline) continue;
      const ev = JSON.parse(dline.slice(6));
      if (ev.kind === "text" && capture) answer += ev.text;
      if (ev.kind === "permission_request") {
        const allow = (ev.options || []).find((o) => /allow/i.test(o.kind)) || ev.options?.[0];
        await fetch(base + "/api/sessions/" + session.id + "/permissions/" + ev.requestId, { method: "POST", headers: H, body: JSON.stringify({ optionId: allow?.optionId }) });
      }
      if (ev.kind === "turn_complete" || ev.kind === "error") onComplete?.(ev);
    }
  }
})().catch(() => {});

function send(text) {
  return new Promise(async (resolve) => {
    onComplete = resolve;
    await fetch(base + "/api/sessions/" + session.id + "/messages", { method: "POST", headers: H, body: JSON.stringify({ text }) });
  });
}

await new Promise((r) => setTimeout(r, 400));
console.log("turn 1: teaching it a number…");
await send("Remember this number for later: 42. Just reply: OK.");

console.log("turn 2: asking it back…");
capture = true;
await send("What number did I ask you to remember? Reply with ONLY the number, nothing else.");
ctrl.abort();

const remembered = /42/.test(answer);
console.log("ANSWER:", answer.trim());
console.log("MULTI-TURN CONTEXT:", remembered ? "PASS ✓ (remembered across turns)" : "FAIL ✗");

const storePath = join(homedir(), ".grok-remote", "sessions.json");
const persisted = existsSync(storePath) && JSON.parse(readFileSync(storePath, "utf8")).some((s) => s.id === session.id);
console.log("PERSISTENCE:", persisted ? "PASS ✓ (session saved to disk)" : "FAIL ✗");
process.exit(0);
