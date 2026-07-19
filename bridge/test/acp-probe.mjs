// Learn the REAL `grok agent stdio` ACP protocol: run the handshake, send a prompt
// that triggers a tool needing approval, and log every JSON-RPC message (responses,
// server->client requests like session/request_permission, and notifications).
//
//   node test/acp-probe.mjs

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { join } from "node:path";

const cwd = join(homedir(), "Developer", "grok-remote", "sandbox");
const grok = join(homedir(), ".grok", "bin", "grok");
const child = spawn(grok, ["agent", "stdio"], { cwd, stdio: ["pipe", "pipe", "pipe"], env: process.env });

let nextId = 1;
const pending = new Map();

function request(method, params) {
  const id = nextId++;
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve) => pending.set(id, resolve));
}
function respond(id, result) {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
  console.log("  ↩ responded to", id, JSON.stringify(result));
}

createInterface({ input: child.stdout }).on("line", (line) => {
  const t = line.trim();
  if (!t) return;
  let msg;
  try { msg = JSON.parse(t); } catch { console.log("  raw:", t.slice(0, 300)); return; }

  if (msg.method && msg.id !== undefined) {
    // server -> client REQUEST
    console.log("⇐ SERVER REQ", msg.id, msg.method, "\n   params:", JSON.stringify(msg.params));
    if (msg.method === "session/request_permission") {
      const opts = msg.params?.options || [];
      const allow = opts.find((o) => /allow/i.test((o.optionId || "") + (o.kind || "") + (o.name || ""))) || opts[0];
      respond(msg.id, { outcome: { outcome: "selected", optionId: allow?.optionId } });
    } else if (msg.method === "_x.ai/exit_plan_mode") {
      respond(msg.id, { approved: true }); // TEST: does this proceed to execute the plan?
    } else {
      respond(msg.id, {}); // fs/terminal we didn't advertise — just ack
    }
  } else if (msg.method) {
    // NOTIFICATION
    const u = msg.params?.update;
    console.log("  · notify", msg.method, u ? "→ " + u.sessionUpdate : JSON.stringify(msg.params).slice(0, 160));
    if (u && u.sessionUpdate && !["agent_message_chunk", "agent_thought_chunk"].includes(u.sessionUpdate)) {
      console.log("     update:", JSON.stringify(u).slice(0, 400));
    }
  } else if (msg.id !== undefined) {
    // RESPONSE to our request
    console.log("← RES", msg.id, JSON.stringify(msg.result ?? { error: msg.error }).slice(0, 500));
    const r = pending.get(msg.id);
    if (r) { pending.delete(msg.id); r(msg.result); }
  }
});
child.stderr.on("data", (d) => console.log("  stderr:", d.toString().trim().slice(0, 200)));

const init = await request("initialize", {
  protocolVersion: "1",
  clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
});
console.log("INIT →", JSON.stringify(init));

const sess = await request("session/new", { cwd, mcpServers: [] });
console.log("SESSION/NEW →", JSON.stringify(sess));
const sessionId = sess?.sessionId;

console.log("--- sending prompt that should require a shell-tool approval ---");
const result = await request("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: process.env.PROMPT || "Use the shell (run_terminal_cmd) to run exactly: echo hello-acp > acp-hello.txt" }],
});
console.log("PROMPT DONE →", JSON.stringify(result));

setTimeout(() => { child.kill(); process.exit(0); }, 1500);
