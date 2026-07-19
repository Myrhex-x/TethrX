// Seeds one completed session for UI screenshots: creates a session in the
// sandbox, runs a turn, waits for completion, then prints "SID <id>". Because the
// bridge replays event history to new subscribers, the app can open this session
// later and show the whole turn.
//
//   node test/demo-session.mjs

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const session = await (await fetch(base + "/api/sessions", {
  method: "POST", headers: H, body: JSON.stringify({ cwd, title: "sandbox" }),
})).json();

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
      if (ev.kind === "turn_complete" || ev.kind === "error") { ctrl.abort(); return; }
    }
  }
})().catch(() => {});

await new Promise((r) => setTimeout(r, 400));
await fetch(base + "/api/sessions/" + session.id + "/messages", {
  method: "POST", headers: H,
  body: JSON.stringify({ text: "List the files in this folder, then tell me in one short sentence what todo.txt is about.", maxTurns: 3 }),
});
await done;
console.log("SID " + session.id);
process.exit(0);
