// End-to-end smoke test: health -> create session -> open SSE -> send one real
// Grok turn -> print every normalized event until the turn completes.
//
//   node test/smoke.mjs
//
// Reads the pairing token straight from ~/.grok-remote/config.json.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = process.env.BASE || "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = process.env.CWD_DIR || join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const health = await (await fetch(base + "/api/health")).json();
console.log("HEALTH", JSON.stringify(health));

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd }),
})).json();
console.log("SESSION", session.id, "cwd:", session.cwd);

const ctrl = new AbortController();
const streamDone = (async () => {
  const res = await fetch(base + "/api/sessions/" + session.id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 2);
      const dline = frame.split("\n").find((l) => l.startsWith("data: "));
      if (!dline) continue;
      const ev = JSON.parse(dline.slice(6));
      console.log("EVENT", JSON.stringify(ev));
      if (ev.kind === "turn_complete" || ev.kind === "error") { ctrl.abort(); return ev; }
    }
  }
})().catch((e) => ({ kind: "stream-aborted", message: String(e.message || e) }));

await new Promise((r) => setTimeout(r, 400)); // let the stream attach first
const accepted = await fetch(base + "/api/sessions/" + session.id + "/messages", {
  method: "POST", headers: H,
  body: JSON.stringify({ text: "Reply with exactly the single word: pong. Do not use any tools.", maxTurns: 1 }),
});
console.log("MESSAGE accepted:", accepted.status);

const result = await streamDone;
console.log("RESULT", JSON.stringify(result));
process.exit(0);
