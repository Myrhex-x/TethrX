// Grok Build process wrapper.
//
// Transport A (implemented): HEADLESS. Spawns `grok -p <prompt> -s <uuid>
// --output-format streaming-json` and parses the newline-delimited JSON event
// stream into normalized events. `-s <uuid>` makes the session multi-turn: the same
// id resumes context across calls.
//
// Transport B (phase 2): ACP via `grok agent stdio` — a persistent JSON-RPC process
// that additionally streams tool_call / plan / permission-request updates, enabling
// approve/reject from the phone. Stubbed at the bottom for the next iteration.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

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
export function runHeadlessTurn(opts) {
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
    "-s", sessionId,
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

    let ended = null;      // captured `end` event payload
    let stderrTail = "";   // keep the last chunk of stderr for error reporting

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
      if (normalized.kind === "end") ended = normalized;
      onEvent(normalized);
    });

    child.stderr.on("data", (buf) => {
      const text = buf.toString();
      stderrTail = (stderrTail + text).slice(-4000);
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
      reject(new Error(`grok exited (code ${code}) without completing.` +
        (stderrTail ? ` stderr: ${stderrTail.trim()}` : "")));
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
