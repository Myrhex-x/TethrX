// Regression checks for the reliability and safety fixes. Pure unit-level: no grok,
// no network, no sockets. Run with:
//
//   node test/verify-fixes.mjs
//
// Each case names the bug it locks down, so a future edit that reintroduces one fails
// with the reason rather than a bare assertion.

import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, statSync, existsSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionStore } from "../src/sessions.mjs";
import { AcpSession } from "../src/acp.mjs";
import * as git from "../src/git.mjs";

let failures = 0;
function check(name, fn) {
  try {
    const r = fn();
    if (r instanceof Promise) return r.then(
      () => console.log(`  ok  ${name}`),
      (e) => { failures++; console.error(`FAIL  ${name}\n      ${e.message}`); }
    );
    console.log(`  ok  ${name}`);
  } catch (e) {
    failures++;
    console.error(`FAIL  ${name}\n      ${e.message}`);
  }
}

const dir = mkdtempSync(join(tmpdir(), "tethrx-test-"));
const store = new SessionStore(join(dir, "sessions.json"));

// --- approval policy --------------------------------------------------------

check("approval policy defaults to asking", () => {
  const s = store.create({ cwd: dir });
  assert.equal(s.approvalPolicy, "ask");
  assert.equal(s.autoApprove, false);
  assert.equal(s.shouldAutoApprove({ readOnly: true }), false);
});

check("the legacy autoApprove boolean still maps both ways", () => {
  const s = store.create({ cwd: dir, autoApprove: true });
  assert.equal(s.approvalPolicy, "all");
  s.autoApprove = false;
  assert.equal(s.approvalPolicy, "ask");
});

check("reads-only approves read-only tools and nothing else", () => {
  const s = store.create({ cwd: dir, approvalPolicy: "reads" });
  assert.equal(s.shouldAutoApprove({ readOnly: true }), true, "a read should pass");
  assert.equal(s.shouldAutoApprove({ readOnly: false }), false, "a write must ask");
  // An unknown tool with no flag must NOT be treated as a read.
  assert.equal(s.shouldAutoApprove({}), false, "a missing flag must not read as read-only");
  assert.equal(s.shouldAutoApprove({ readOnly: "true" }), false, "only a real true counts");
});

check("toJSON still carries autoApprove for clients that predate the policy", () => {
  const s = store.create({ cwd: dir, approvalPolicy: "all" });
  assert.equal(s.toJSON().autoApprove, true);
  assert.equal(s.toJSON().approvalPolicy, "all");
});

// --- deleting a session mid-turn --------------------------------------------

check("a deleted session stops emitting, queueing and rewriting its transcript", () => {
  const s = store.create({ cwd: dir });
  s.emit({ kind: "text", text: "before" });
  const path = s.historyPath;
  s.saveHistory();
  assert.ok(existsSync(path), "precondition: the transcript exists");

  store.delete(s.id);
  assert.equal(s.dead, true);
  // The turn still holds the object and unwinds through its own finally.
  assert.equal(s.emit({ kind: "text", text: "after" }), 0, "emit must be inert once dead");
  assert.equal(s.enqueue("follow-up"), null, "a dead session must not accept queued work");
  s.saveHistory();
  assert.equal(existsSync(path), false, "saveHistory resurrected the deleted transcript");
});

check("orphaned transcripts are swept", () => {
  const orphan = join(dir, "history", "11111111-2222-3333-4444-555555555555.json");
  writeFileSync(orphan, "[]");
  const removed = store.sweepOrphanHistory(readdirSync);
  assert.ok(removed >= 1, "the orphan should have been removed");
  assert.equal(existsSync(orphan), false);
});

// --- persistence ------------------------------------------------------------

check("transcripts and the session store are written 0600", () => {
  const s = store.create({ cwd: dir });
  s.emit({ kind: "text", text: "private" });
  s.saveHistory();
  store.save();
  assert.equal(statSync(s.historyPath).mode & 0o777, 0o600, "transcript is world-readable");
  assert.equal(statSync(join(dir, "sessions.json")).mode & 0o777, 0o600, "session store is world-readable");
});

check("a corrupt store is set aside rather than silently starting empty", () => {
  const d2 = mkdtempSync(join(tmpdir(), "tethrx-corrupt-"));
  const p = join(d2, "sessions.json");
  writeFileSync(p, '[{"id":"x","cwd":"/tmp"');   // truncated mid-write
  const s2 = new SessionStore(p);
  assert.equal(s2.list().length, 0);
  assert.ok(existsSync(p + ".corrupt"), "the unreadable file should be kept for diagnosis");
  rmSync(d2, { recursive: true, force: true });
});

// --- SSE --------------------------------------------------------------------

check("the command roster streams but is never stored in the transcript", () => {
  const s = store.create({ cwd: dir });
  const frames = [];
  const fake = { write: (f) => frames.push(f), on: () => {}, writableLength: 0 };
  s.subscribe(fake, 0);

  const before = s._events.length;
  s.emit({ kind: "commands", commands: [{ name: "compact" }] });
  assert.equal(s._events.length, before, "commands must not consume history slots");
  assert.ok(frames.some((f) => f.includes('"kind":"commands"')), "commands must still reach subscribers");
  // No id line, so a reconnect's Last-Event-ID position is untouched.
  assert.ok(!frames[frames.length - 1].startsWith("id:"), "an ephemeral frame must carry no event id");

  s.emit({ kind: "text", text: "real" });
  assert.equal(s._events.length, before + 1, "real events are still persisted");
});

check("a subscriber that stops reading is dropped instead of buffering forever", () => {
  const s = store.create({ cwd: dir });
  let destroyed = false;
  const stalled = {
    write: () => {},
    on: () => {},
    writableLength: 64 * 1024 * 1024,     // way past the ceiling
    destroy: () => { destroyed = true; },
  };
  s.subscribe(stalled, 0);
  s.emit({ kind: "text", text: "x" });
  assert.equal(destroyed, true, "a wedged subscriber should be destroyed");
  assert.equal(s.subscriberCount, 0);
});

// --- waiting state ----------------------------------------------------------

check("waiting state is exposed and cleared", () => {
  const s = store.create({ cwd: dir });
  assert.equal(s.toJSON().waiting, undefined);
  s.setWaiting("permission", "rm -rf build");
  assert.equal(s.toJSON().waiting.kind, "permission");
  assert.equal(s.toJSON().waiting.label, "rm -rf build");
  s.clearWaiting();
  assert.equal(s.toJSON().waiting, undefined);
});

// --- ACP --------------------------------------------------------------------

function acp() {
  return new AcpSession({ grokBin: "/nonexistent", cwd: dir, onEvent: () => {} });
}

check("permission ids are namespaced per process", () => {
  const a = acp(), b = acp();
  assert.notEqual(a._tag(0), b._tag(0),
    "two processes both numbering from 0 would let a stale card resolve an unrelated request");
  assert.equal(a._tag(0), a._tag(0), "the tag must be stable within one process");
});

check("running() reports a dead child as dead", () => {
  const a = acp();
  assert.equal(a.running, false, "no process at all is not running");
  a.proc = { killed: false, exitCode: 1, signalCode: null, stdin: { writable: true } };
  assert.equal(a.running, false, "a child that exited on its own is not running");
  a.proc = { killed: false, exitCode: null, signalCode: "SIGKILL", stdin: { writable: true } };
  assert.equal(a.running, false, "a signalled child is not running");
  a.proc = { killed: false, exitCode: null, signalCode: null, stdin: { writable: false } };
  assert.equal(a.running, false, "a closed stdin is not writable");
  a.proc = { killed: false, exitCode: null, signalCode: null, stdin: { writable: true } };
  assert.equal(a.running, true);
});

check("sending to a dead child throws instead of writing into the void", () => {
  const a = acp();
  assert.throws(() => a._send({ jsonrpc: "2.0" }), /not running/);
});

check("abandoned permissions and plans are resolved when grok dies", () => {
  const events = [];
  const a = new AcpSession({ grokBin: "/nonexistent", cwd: dir, onEvent: (e) => events.push(e) });
  a._permissions.set(a._tag(0), 0);
  a._plans.set(a._tag(1), 1);
  a._failPending(new Error("grok agent exited"));
  const perm = events.find((e) => e.kind === "permission_resolved");
  const plan = events.find((e) => e.kind === "plan_resolved");
  assert.ok(perm && perm.abandoned, "a pending approval must be resolved, not left to replay forever");
  assert.ok(plan && plan.abandoned, "a pending plan review must be resolved too");
  assert.equal(a._permissions.size, 0);
  assert.equal(a._plans.size, 0);
});

check("the closed event names the process that died", () => {
  const events = [];
  const a = new AcpSession({ grokBin: "/nonexistent", cwd: dir, onEvent: (e) => events.push(e) });
  // Mimic the close handler's payload; the server compares this against session.acp so
  // a dying child cannot null out the replacement installed before it fired.
  a.onEvent({ kind: "closed", acp: a });
  assert.equal(events[0].acp, a);
});

// --- command routing --------------------------------------------------------

function routeAll(raw) {
  const out = {};
  const a = new AcpSession({
    grokBin: "/nonexistent", cwd: dir,
    onEvent: (e) => { if (e.kind === "commands") for (const c of e.commands) out[c.name] = c; },
  });
  a._adoptCommands(raw);
  return out;
}

const GROK_1 = [
  { name: "compact", _meta: { scope: "builtin" } },
  { name: "context", _meta: { scope: "builtin" } },
  { name: "session-info", _meta: { scope: "builtin" } },
  { name: "always-approve", _meta: { scope: "builtin" } },
  { name: "workflow", _meta: { scope: "builtin" } },
  { name: "goal", _meta: { scope: "builtin" } },
  { name: "deep-research", _meta: { scope: "builtin" } },
  { name: "loop", _meta: { scope: "builtin" } },
  { name: "my-skill", _meta: { scope: "user" } },
];

const GROK_0_2 = [
  { name: "compact", _meta: { scope: "builtin" } },
  { name: "context", _meta: { scope: "builtin" } },
  { name: "always-approve", _meta: { scope: "builtin" } },
  { name: "my-skill", _meta: { scope: "user" } },
];

check("grok 1.0.0: the built-ins that really execute are routed to grok", () => {
  const c = routeAll(GROK_1);
  for (const name of ["workflow", "goal"]) {
    assert.equal(c[name].routing, "send", `/${name} executes over ACP on 1.0.0`);
    assert.notEqual(c[name].scope, "builtin",
      `/${name} must not read as builtin, or the shipped App Store build hides it`);
  }
});

check("always-approve is NEVER forwarded to grok", () => {
  // Forwarding it would flip grok's own permission mode, which stops
  // session/request_permission arriving at all: the phone's approval cards would
  // silently vanish while the toggle still said "Ask each time".
  assert.equal(routeAll(GROK_1)["always-approve"].routing, "auto-approve");
  assert.equal(routeAll(GROK_1)["always-approve"].scope, "builtin");
  assert.equal(routeAll(GROK_0_2)["always-approve"].routing, "auto-approve");
});

check("expensive commands are flagged and hidden from clients that cannot warn", () => {
  const c = routeAll(GROK_1);
  for (const name of ["deep-research", "loop"]) {
    assert.equal(c[name].costly, true, `/${name} costs a full paid turn`);
    assert.equal(c[name].scope, "builtin", `/${name} must stay hidden on clients with no confirmation step`);
  }
});

check("grok 0.2.x keeps the old, narrower routing", () => {
  const c = routeAll(GROK_0_2);
  assert.equal(c.context.routing, "details");
  assert.equal(c.compact.routing, "hidden", "compact really was inert on 0.2.x");
  assert.equal(c["my-skill"].routing, "send", "skills always ran as a normal turn");
});

check("grok's own classification survives alongside the routing hint", () => {
  const c = routeAll(GROK_1);
  assert.equal(c.workflow.kind, "builtin", "the real scope must stay readable for the badge");
  assert.equal(c["my-skill"].kind, "user");
});

// --- git --------------------------------------------------------------------

await check("the git diff endpoint cannot read outside the repo", async () => {
  const outside = join(dir, "outside-secret.txt");
  writeFileSync(outside, "pairing token lives here");
  // Not a repo, so diff() short-circuits; assert the jail directly instead.
  const { execFileSync } = await import("node:child_process");
  const repo = join(dir, "repo");
  execFileSync("mkdir", ["-p", repo]);
  execFileSync("git", ["init", "-q", "."], { cwd: repo });
  execFileSync("git", ["config", "user.email", "t@t.t"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "t"], { cwd: repo });
  writeFileSync(join(repo, "a.txt"), "one\n");
  execFileSync("git", ["add", "-A"], { cwd: repo });
  execFileSync("git", ["commit", "-qm", "init"], { cwd: repo });
  writeFileSync(join(repo, "a.txt"), "two\n");

  assert.equal(await git.diff(repo, outside), "", "an absolute path outside the repo must be refused");
  assert.equal(await git.diff(repo, "../outside-secret.txt"), "", "traversal must be refused");
  assert.equal(await git.diff(repo, "--output=/tmp/x"), "", "option-shaped input must be refused");
  assert.ok((await git.diff(repo, "a.txt")).includes("+two"), "a legitimate diff must still work");
});

await check("discard reverts STAGED changes and reports honestly", async () => {
  const { execFileSync } = await import("node:child_process");
  const repo = join(dir, "repo2");
  execFileSync("mkdir", ["-p", repo]);
  execFileSync("git", ["init", "-q", "."], { cwd: repo });
  execFileSync("git", ["config", "user.email", "t@t.t"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "t"], { cwd: repo });
  writeFileSync(join(repo, "t.txt"), "v1\n");
  execFileSync("git", ["add", "-A"], { cwd: repo });
  execFileSync("git", ["commit", "-qm", "init"], { cwd: repo });
  // commit() runs `git add -A`, so a rejected commit leaves everything staged. The old
  // `checkout -- .` copied the index back over the worktree and changed nothing at all,
  // while still reporting success.
  writeFileSync(join(repo, "t.txt"), "v2\n");
  writeFileSync(join(repo, "new.txt"), "added\n");
  execFileSync("git", ["add", "-A"], { cwd: repo });

  const r = await git.discard(repo);
  assert.equal(r.ok, true);
  assert.equal(readFileSync(join(repo, "t.txt"), "utf8"), "v1\n", "a staged edit survived the discard");
  assert.equal(existsSync(join(repo, "new.txt")), false, "a staged new file survived the discard");
});

await check("non-ASCII filenames survive the status parser", async () => {
  const { execFileSync } = await import("node:child_process");
  const repo = join(dir, "repo3");
  execFileSync("mkdir", ["-p", repo]);
  execFileSync("git", ["init", "-q", "."], { cwd: repo });
  execFileSync("git", ["config", "user.email", "t@t.t"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "t"], { cwd: repo });
  writeFileSync(join(repo, "café.txt"), "un\n");
  execFileSync("git", ["add", "-A"], { cwd: repo });
  execFileSync("git", ["commit", "-qm", "init"], { cwd: repo });
  writeFileSync(join(repo, "café.txt"), "deux\n");

  const st = await git.status(repo);
  const f = st.files.find((x) => x.path.includes("caf"));
  // Without -z, core.quotePath yields the escaped literal "caf\303\251.txt", which the
  // phone displayed verbatim and whose diff always came back empty.
  assert.equal(f.path, "café.txt", `got ${JSON.stringify(f.path)}`);
  assert.ok((await git.diff(repo, f.path)).includes("+deux"), "its diff must not be empty");
});

// --- turn stopwatch ---------------------------------------------------------

check("a running turn reports when it started, and stops reporting when it ends", () => {
  const s = store.create({ cwd: dir });
  assert.equal(s.toJSON().runningSince, undefined, "an idle session has no start time");
  s.beginTurn();
  const started = s.toJSON().runningSince;
  assert.ok(started && !Number.isNaN(Date.parse(started)), `runningSince must be a date, got ${started}`);
  // The phone renders a stopwatch from this, so a stale value would show a turn
  // that finished minutes ago as still going.
  s.endTurn();
  assert.equal(s.toJSON().runningSince, undefined, "an ended turn clears its start time");
});

// --- an answerable waiting state ----------------------------------------------

check("waiting carries what it takes to answer it", () => {
  const s = store.create({ cwd: dir });
  s.setWaiting("permission", "rm -rf .build", { requestId: "req-1", allow: "yes", deny: "no" });
  const w = s.toJSON().waiting;
  assert.equal(w.kind, "permission");
  assert.equal(w.label, "rm -rf .build");
  // Without these three a small client can SEE the block and not answer it, which
  // is the entire difference between a watch app and a notification.
  assert.equal(w.requestId, "req-1");
  assert.equal(w.allow, "yes");
  assert.equal(w.deny, "no");
  s.clearWaiting();
  assert.equal(s.toJSON().waiting, undefined);
});

check("the transcript tail is bounded and ordered oldest first", () => {
  const s = store.create({ cwd: dir });
  for (let i = 0; i < 10; i++) s.emit({ kind: "text", text: `chunk ${i}` });
  const tail = s.tail(3);
  assert.equal(tail.length, 3);
  assert.equal(tail[0].event.text, "chunk 7");
  assert.equal(tail[2].event.text, "chunk 9");
  // A client asking for everything must not be able to ask for more than the cap.
  assert.ok(s.tail(100000).length <= 500);
});

rmSync(dir, { recursive: true, force: true });

console.log(failures ? `\n${failures} check(s) FAILED` : "\nall checks passed");
process.exit(failures ? 1 : 0);
