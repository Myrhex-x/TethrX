// Verify per-session config + "always allow": with autoApprove on, a shell tool runs
// WITHOUT emitting a permission_request (no prompt), and the file is created.
import { readFileSync, existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };
const target = join(cwd, "autoapprove.txt");
rmSync(target, { force: true });

// autoApprove at creation
const s = await (await fetch(base + "/api/sessions", { method: "POST", headers: H, body: JSON.stringify({ cwd, title: "auto", autoApprove: true, effort: "low" }) })).json();
console.log("created — autoApprove:", s.autoApprove, "effort:", s.effort);

// also exercise the live config endpoint (toggle plan on/off)
const cfg = await (await fetch(base + "/api/sessions/" + s.id + "/config", { method: "POST", headers: H, body: JSON.stringify({ planMode: true }) })).json();
console.log("config endpoint — planMode now:", cfg.planMode);
await fetch(base + "/api/sessions/" + s.id + "/config", { method: "POST", headers: H, body: JSON.stringify({ planMode: false }) });

let sawPermission = false;
const ctrl = new AbortController();
const done = (async () => {
  const res = await fetch(base + "/api/sessions/" + s.id + "/stream", { headers: H, signal: ctrl.signal });
  const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = "";
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const f = buf.slice(0, i); buf = buf.slice(i + 2);
      const d = f.split("\n").find((l) => l.startsWith("data: ")); if (!d) continue;
      const ev = JSON.parse(d.slice(6));
      if (ev.kind === "permission_request") sawPermission = true;
      if (ev.kind === "turn_complete" || ev.kind === "error") { ctrl.abort(); return; }
    }
  }
})().catch(() => {});

await new Promise((r) => setTimeout(r, 400));
await fetch(base + "/api/sessions/" + s.id + "/messages", { method: "POST", headers: H, body: JSON.stringify({ text: "Use the shell to run exactly: echo auto > autoapprove.txt" }) });
await done;

console.log("PERMISSION PROMPT SHOWN:", sawPermission ? "yes ✗" : "no ✓ (auto-approved)");
console.log("FILE CREATED:", existsSync(target) ? "PASS ✓ (tool ran without prompting)" : "FAIL ✗");
process.exit(0);
