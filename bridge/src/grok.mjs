// Grok Build process wrapper.
//
// Transport A (implemented): HEADLESS. Spawns `grok -p <prompt>
// --output-format streaming-json` and parses the newline-delimited JSON event
// stream into normalized events.
//
// `-s <uuid>` does NOT make a session multi-turn. On grok 1.0.0 it names a NEW
// conversation and refuses a uuid that already exists, so every turn after the
// first exited 1 with an empty stdout and "Session ID ... is already in use" on
// stderr; with no `end` event to parse, that surfaced on the phone as the
// useless "grok exited (code 1) without completing". Turn one creates the
// session with `-s`, every turn after it continues with `--resume <uuid>`.
//
// Transport B (phase 2): ACP via `grok agent stdio` — a persistent JSON-RPC process
// that additionally streams tool_call / plan / permission-request updates, enabling
// approve/reject from the phone. Stubbed at the bottom for the next iteration.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

/** grok's refusal to reuse a session uuid, the signal that this turn must resume. */
const SESSION_IN_USE = /session id .* is already in use/i;

// Session uuids grok has demonstrably created (we saw an `end` event for them),
// so the next turn must use `--resume`. Deliberately not derived from the
// session's turn count: the server increments that before the turn runs, and
// `--resume` on a uuid grok has never seen fails a different way. After a bridge
// restart the set is empty, so the first turn of an existing session pays for one
// discovery spawn, which costs no tokens (grok rejects the id before any model call).
const resumable = new Set();

/**
 * Run a single Grok turn headlessly, streaming normalized events via `onEvent`.
 *
 * Normalized event kinds emitted:
 *   { kind: "text",    text }              incremental assistant text
 *   { kind: "thought", text }              reasoning trace
 *   { kind: "end",     stopReason, sessionId, requestId }
 *   { kind: "log",     text }              diagnostic (grok stderr)
 *   { kind: "raw",     raw }               any future/unknown event type, passed through
 *
 * @returns {Promise<{sessionId:string, stopReason:string}>}
 */
export async function runHeadlessTurn(opts) {
  if (resumable.has(opts.sessionId)) return spawnTurn(opts, true);
  try {
    return await spawnTurn(opts, false);
  } catch (err) {
    // The session already exists (created by an earlier run of this bridge, or by
    // a turn we cancelled before its `end`). Retry once in the resume form.
    if (!err?.sessionIdInUse || opts.signal?.aborted) throw err;
    resumable.add(opts.sessionId);
    return spawnTurn(opts, true);
  }
}

function spawnTurn(opts, resume) {
  const {
    grokBin,
    prompt,
    sessionId,
    cwd,
    model,
    permissionMode,
    alwaysApprove = false,
    maxTurns,
    allow = [],
    deny = [],
    signal,
    onEvent,
  } = opts;

  const args = [
    "-p", prompt,
    // Never both: grok only accepts `-s` alongside `--resume` when forking.
    ...(resume ? ["--resume", sessionId] : ["-s", sessionId]),
    "--output-format", "streaming-json",
  ];
  if (model) args.push("-m", model);
  if (cwd) args.push("--cwd", cwd);
  if (permissionMode) args.push("--permission-mode", permissionMode);
  if (alwaysApprove) args.push("--always-approve");
  if (maxTurns) args.push("--max-turns", String(maxTurns));
  for (const rule of allow) args.push("--allow", rule);
  for (const rule of deny) args.push("--deny", rule);

  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(grokBin, args, {
        cwd,
        signal,
        stdio: ["ignore", "pipe", "pipe"],
        env: process.env,
      });
    } catch (err) {
      reject(err);
      return;
    }

    let ended = null;        // captured `end` event payload
    let stderrTail = "";     // keep the last chunk of stderr for error reporting
    let sessionInUse = false; // grok refused the uuid; the caller retries with --resume

    const rl = createInterface({ input: child.stdout });
    rl.on("line", (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let obj;
      try {
        obj = JSON.parse(trimmed);
      } catch {
        // Non-JSON line on stdout — surface as a log rather than crashing the parser.
        onEvent({ kind: "log", text: trimmed });
        return;
      }
      const normalized = normalize(obj);
      if (normalized.kind === "end") {
        ended = normalized;
        // Grok has persisted the conversation, so the id is spent: the next turn
        // has to resume it. Recorded here rather than on resolve because a turn
        // cancelled before its `end` may never have created the session.
        resumable.add(sessionId);
      }
      onEvent(normalized);
    });

    child.stderr.on("data", (buf) => {
      const text = buf.toString();
      stderrTail = (stderrTail + text).slice(-4000);
      if (!sessionInUse && SESSION_IN_USE.test(stderrTail)) {
        // Ours to handle, not the user's to read: the retry below re-runs the
        // same prompt, so don't drop a scary line into the transcript first.
        sessionInUse = true;
        return;
      }
      onEvent({ kind: "log", text: text.trimEnd() });
    });

    child.on("error", (err) => {
      // e.g. ENOENT when grok isn't installed / wrong path.
      reject(new Error(`failed to launch grok (${grokBin}): ${err.message}`));
    });

    child.on("close", (code, sig) => {
      if (ended) {
        resolve({ sessionId: ended.sessionId || sessionId, stopReason: ended.stopReason });
        return;
      }
      if (signal?.aborted || sig === "SIGTERM") {
        resolve({ sessionId, stopReason: "Cancelled" });
        return;
      }
      const err = new Error(`grok exited (code ${code}) without completing.` +
        (stderrTail ? ` stderr: ${stderrTail.trim()}` : ""));
      if (sessionInUse) err.sessionIdInUse = true;
      reject(err);
    });
  });
}

// Map a raw grok streaming-json event onto our normalized shape.
function normalize(obj) {
  switch (obj.type) {
    case "text":
      return { kind: "text", text: obj.data ?? "" };
    case "thought":
      return { kind: "thought", text: obj.data ?? "" };
    case "end":
      return {
        kind: "end",
        stopReason: obj.stopReason ?? "EndTurn",
        sessionId: obj.sessionId,
        requestId: obj.requestId,
      };
    // Grok may add tool_call / plan events to the headless stream in future versions;
    // pass anything unrecognized through untouched so the client can render it.
    default:
      return { kind: "raw", raw: obj };
  }
}

/** Quick capability probe used by /api/health. Resolves the grok version string. */
export function grokVersion(grokBin) {
  return new Promise((resolve) => {
    let out = "";
    const child = spawn(grokBin, ["--version"], { stdio: ["ignore", "pipe", "ignore"] });
    child.stdout.on("data", (b) => (out += b.toString()));
    child.on("error", () => resolve(null));
    child.on("close", () => resolve(out.trim() || null));
  });
}
