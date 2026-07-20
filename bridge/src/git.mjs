// Git inspection + commit/discard for a session's working directory, so you can
// review what Grok actually changed from the phone instead of walking to the machine.
//
// Scoped to the session's own cwd. This grants nothing the bridge couldn't already
// do (Grok runs shell there), but `discard` destroys uncommitted work, so the app
// must confirm it explicitly.

import { execFile } from "node:child_process";

const MAX_DIFF = 200_000;

function run(args, cwd, timeout = 15000) {
  return new Promise((resolve) => {
    execFile("git", args, { cwd, timeout, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({
        ok: !err,
        stdout: stdout || "",
        stderr: stderr || String(err?.message || ""),
      });
    });
  });
}

export async function isRepo(cwd) {
  if (!cwd) return false;
  const r = await run(["rev-parse", "--is-inside-work-tree"], cwd);
  return r.ok && r.stdout.trim() === "true";
}

/** Branch + every changed file, untracked included. */
export async function status(cwd) {
  if (!(await isRepo(cwd))) return { repo: false, files: [] };
  const [branch, porcelain] = await Promise.all([
    run(["rev-parse", "--abbrev-ref", "HEAD"], cwd),
    run(["status", "--porcelain=v1", "--untracked-files=all"], cwd),
  ]);
  const files = porcelain.stdout
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const code = line.slice(0, 2);
      let path = line.slice(3);
      const arrow = path.indexOf(" -> ");        // renames: "old -> new"
      if (arrow !== -1) path = path.slice(arrow + 4);
      return { path, code: code.trim() || "?", staged: code[0] !== " " && code[0] !== "?" };
    });
  return { repo: true, branch: branch.stdout.trim(), files };
}

/** Unified diff for one file (untracked files render as all-additions). */
export async function diff(cwd, file) {
  if (!(await isRepo(cwd))) return "";
  // `file` comes from a query parameter. Every git invocation below must put it after
  // a `--` separator, or a value like "--output=/path" is parsed as an OPTION and git
  // truncates that file while parsing, before it even validates the arguments.
  if (file && file.startsWith("-")) return "";
  const target = file ? ["--", file] : [];
  let out = (await run(["diff", "--no-color", "HEAD", ...target], cwd)).stdout;
  if (!out && file) {
    out = (await run(["diff", "--no-color", "--no-index", "--", "/dev/null", file], cwd)).stdout;
  }
  if (out.length > MAX_DIFF) out = out.slice(0, MAX_DIFF) + "\n… (truncated)";
  return out;
}

export async function commit(cwd, message) {
  if (!(await isRepo(cwd))) return { ok: false, error: "not a git repository" };
  const add = await run(["add", "-A"], cwd);
  if (!add.ok) return { ok: false, error: add.stderr };
  const c = await run(["commit", "-m", message], cwd);
  return { ok: c.ok, output: (c.stdout || c.stderr).trim() };
}

/** Destructive: reverts tracked files and removes untracked ones. */
export async function discard(cwd) {
  if (!(await isRepo(cwd))) return { ok: false, error: "not a git repository" };
  const revert = await run(["checkout", "--", "."], cwd);
  const clean = await run(["clean", "-fd"], cwd);
  return { ok: revert.ok && clean.ok, output: [revert.stdout, clean.stdout].filter(Boolean).join("\n").trim() };
}
