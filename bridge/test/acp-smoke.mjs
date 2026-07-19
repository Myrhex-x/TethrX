// End-to-end ACP test: create an ACP session, stream it, send a prompt that needs a
// shell tool (which should prompt), auto-approve the permission, and confirm the tool
// runs and the turn completes.
//
//   node test/acp-smoke.mjs

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "acp-test" }),
})).json();
console.log("SESSION", session.id, "transport:", session.transport);

const ctrl = new AbortController();
const done = (async () => {
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

      if (ev.kind === "text") process.stdout.write(ev.text);
      else if (ev.kind !== "thought") {
        console.log("\nEVENT", ev.kind, JSON.stringify({ tool: ev.tool, title: ev.title, status: ev.status, exitCode: ev.exitCode, options: ev.options, stopReason: ev.stopReason, message: ev.message }).replace(/null,?|"(tool|title|status|exitCode|options|stopReason|message)":/g, "").slice(0, 200));
      }

      if (ev.kind === "permission_request") {
        const allow = (ev.options || []).find((o) => /allow/i.test(o.kind || o.optionId)) || ev.options?.[0];
        console.log("  → APPROVING with", allow?.optionId);
        await fetch(base + "/api/sessions/" + session.id + "/permissions/" + ev.requestId, {
          method: "POST", headers: H, body: JSON.stringify({ optionId: allow?.optionId }),
        });
      }
      if (ev.kind === "turn_complete" || ev.kind === "error") { ctrl.abort(); return ev; }
    }
  }
})().catch((e) => ({ kind: "streamerr", message: String(e) }));

await new Promise((r) => setTimeout(r, 500));
await fetch(base + "/api/sessions/" + session.id + "/messages", {
  method: "POST", headers: H, body: JSON.stringify({ text: "Use the shell to run exactly: echo acp-works > acp-works.txt" }),
});

const result = await done;
console.log("\nRESULT", result?.kind, result?.stopReason || result?.message || "");
process.exit(0);
