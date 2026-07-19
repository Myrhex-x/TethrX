// End-to-end plan mode: create a plan-mode session, receive the plan for review,
// approve it, auto-approve execution tools, and confirm the file gets built.

import { readFileSync, existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };
const target = join(cwd, "greet.py");
rmSync(target, { force: true });

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "plan-test", planMode: true }),
})).json();
console.log("SESSION", session.id, "planMode:", session.planMode);

let turnCompletes = 0;
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

      if (ev.kind === "mode") console.log("MODE →", ev.mode);
      if (ev.kind === "plan_review") {
        console.log("PLAN REVIEW (first 180 chars):\n ", (ev.planContent || "").slice(0, 180).replace(/\n/g, "\n  "));
        console.log("→ APPROVING plan");
        await fetch(base + "/api/sessions/" + session.id + "/plan/" + ev.requestId, { method: "POST", headers: H, body: JSON.stringify({ approved: true }) });
      }
      if (ev.kind === "permission_request") {
        const allow = (ev.options || []).find((o) => /allow/i.test(o.kind)) || ev.options?.[0];
        await fetch(base + "/api/sessions/" + session.id + "/permissions/" + ev.requestId, { method: "POST", headers: H, body: JSON.stringify({ optionId: allow?.optionId }) });
      }
      if (ev.kind === "tool_call") console.log("  tool:", ev.tool, ev.command ? "→ " + ev.command : "");
      if (ev.kind === "turn_complete") { turnCompletes++; if (turnCompletes >= 2 || existsSync(target)) { ctrl.abort(); return "done"; } }
      if (ev.kind === "error") { ctrl.abort(); return "error"; }
    }
  }
})().catch(() => "streamerr");

await new Promise((r) => setTimeout(r, 500));
await fetch(base + "/api/sessions/" + session.id + "/messages", {
  method: "POST", headers: H, body: JSON.stringify({ text: "Create greet.py with a greet(name) function returning 'Hello, <name>!'. Plan first." }),
});

// Safety timeout so we don't hang.
const timeout = new Promise((r) => setTimeout(() => { ctrl.abort(); r("timeout"); }, 90000));
await Promise.race([done, timeout]);
console.log("greet.py built:", existsSync(target) ? "PASS ✓ (plan reviewed → approved → executed)" : "FAIL ✗");
process.exit(0);
