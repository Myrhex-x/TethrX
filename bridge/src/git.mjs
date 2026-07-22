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

// rev-parse either answers instantly or the dir is on a dead mount — and
// candidateRepos runs a batch of these per Changes-screen refresh, so a short
// timeout is what keeps one hung path from freezing the whole review.
const ROOT_TIMEOUT = 3000;

export async function isRepo(cwd) {
  if (!cwd) return false;
  const r = await run(["rev-parse", "--is-inside-work-tree"], cwd);
  return r.ok && r.stdout.trim() === "true";
}

/** Absolute repo root containing `dir`, or null. */
export async function repoRoot(dir) {
  if (!dir) return null;
  const r = await run(["rev-parse", "--show-toplevel"], dir, ROOT_TIMEOUT);
  const root = r.stdout.trim();
  return r.ok && root.startsWith("/") ? root : null;
}

/**
 * The repos a session actually touched. Sessions usually start in ~ (not a repo)
 * while grok edits files somewhere deeper — resolve each edited file's repo so the
 * phone's Changes screen can review THOSE instead of reporting "not a repository".
 * Newest-edit-first. The session cwd's own repo is included and FLAGGED (`own`):
 * comparing cwd strings against git's resolved roots breaks under symlinks
 * (/tmp vs /private/tmp), so the flag — not string prefixes — is what marks the
 * default review target.
 */
export async function candidateRepos(editedPaths, cwd) {
  const dirs = [];
  const seenDir = new Set();
  for (const p of [...(editedPaths || [])].reverse()) {   // newest edits first
    if (typeof p !== "string" || !p.startsWith("/")) continue;
    const dir = p.slice(0, p.lastIndexOf("/")) || "/";
    if (seenDir.has(dir)) continue;
    seenDir.add(dir);
    dirs.push(dir);
    if (dirs.length >= 25) break;                          // bound the git spawns
  }
  const [ownRoot, ...editRoots] = await Promise.all([repoRoot(cwd), ...dirs.map(repoRoot)]);
  const out = [];
  const seenRoot = new Set();
  for (const root of editRoots) {
    if (root && !seenRoot.has(root)) {
      seenRoot.add(root);
      out.push({ root, name: root.split("/").filter(Boolean).pop() || root, own: root === ownRoot });
    }
  }
  if (ownRoot && !seenRoot.has(ownRoot)) {
    out.push({ root: ownRoot, name: ownRoot.split("/").filter(Boolean).pop() || ownRoot, own: true });
  }
  return out;
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
