// Phase 1: create a session, run a turn that teaches a fact, print the SID (stdout).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "resume-test" }),
})).json();

const ctrl = new AbortController();
const done = (async () => {
  const res = await fetch(base + "/api/sessions/" + session.id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = "";
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const f = buf.slice(0, i); buf = buf.slice(i + 2);
      const d = f.split("\n").find((l) => l.startsWith("data: ")); if (!d) continue;
      const ev = JSON.parse(d.slice(6));
      if (ev.kind === "turn_complete" || ev.kind === "error") { ctrl.abort(); return; }
    }
  }
})().catch(() => {});
await new Promise((r) => setTimeout(r, 400));
await fetch(base + "/api/sessions/" + session.id + "/messages", { method: "POST", headers: H, body: JSON.stringify({ text: "Remember the secret number: 77. Reply just: OK." }) });
await done;
console.error("phase1 done, taught 77");
console.log(session.id); // stdout = just the SID
process.exit(0);
