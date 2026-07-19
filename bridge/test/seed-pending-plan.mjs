// Seed a plan-mode session that reaches plan review and LEAVE it pending, so the app
// can open it and show the plan card. Prints "PENDING <sid> <reqId>".
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "plan-demo", planMode: true }),
})).json();

const ctrl = new AbortController();
const wait = (async () => {
  const res = await fetch(base + "/api/sessions/" + session.id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = "";
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const f = buf.slice(0, i); buf = buf.slice(i + 2);
      const d = f.split("\n").find((l) => l.startsWith("data: ")); if (!d) continue;
      const ev = JSON.parse(d.slice(6));
      if (ev.kind === "plan_review") { ctrl.abort(); return ev.requestId; }
      if (ev.kind === "error" || ev.kind === "turn_complete") { ctrl.abort(); return null; }
    }
  }
})().catch(() => null);

await new Promise((r) => setTimeout(r, 500));
await fetch(base + "/api/sessions/" + session.id + "/messages", {
  method: "POST", headers: H, body: JSON.stringify({ text: "Create fizzbuzz.py with a fizzbuzz(n) function and a small test. Plan it out first." }),
});
const reqId = await wait;
console.log(reqId ? `PENDING ${session.id} ${reqId}` : `NO-PLAN ${session.id}`);
process.exit(0);
