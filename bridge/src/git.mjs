// Git inspection + commit/discard for a session's working directory, so you can
// review what Grok actually changed from the phone instead of walking to the machine.
//
// Scoped to the session's own cwd. This grants nothing the bridge couldn't already
// do (Grok runs shell there), but `discard` destroys uncommitted work, so the app
// must confirm it explicitly.

import { execFile } from "node:child_process";
import { resolve as resolvePath, sep } from "node:path";

const MAX_DIFF = 200_000;

/**
 * Confine a caller-supplied path to the repo.
 *
 * `file` arrives from a query parameter. The all-additions fallback below uses
 * `--no-index`, which will happily diff an ABSOLUTE or `../` path, so this route was
 * a read of any file the user could read (~/.ssh, the bridge's own config.json with
 * the pairing token in it) dressed up as a diff. Returns a repo-relative path, or null.
 */
function confine(cwd, file) {
  if (typeof file !== "string" || !file) return null;
  if (file.startsWith("-")) return null;          // never let a value be parsed as an option
  if (file.includes("\0")) return null;
  const root = resolvePath(cwd);
  const full = resolvePath(root, file);
  if (full !== root && !full.startsWith(root + sep)) return null;
  const rel = full.slice(root.length + 1);
  return rel || null;
}

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
    // -z is not cosmetic. Without it core.quotePath renders any non-ASCII name as an
    // escaped literal ("caf\303\251.txt"), which the phone then showed verbatim and
    // whose diff always came back empty. That is every accented, Cyrillic, Japanese
    // and Chinese filename, in an app shipped in ja and zh-Hans. NUL framing also
    // retires the " -> " rename split, which broke on a filename containing " -> ".
    run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd),
  ]);
  const files = [];
  const records = porcelain.stdout.split("\0");
  for (let i = 0; i < records.length; i++) {
    const line = records[i];
    if (!line) continue;
    const code = line.slice(0, 2);
    let path = line.slice(3);
    // With -z a rename is TWO records: "R  <new>" then the old name on its own.
    if (code[0] === "R" || code[1] === "R") i++;
    files.push({ path, code: code.trim() || "?", staged: code[0] !== " " && code[0] !== "?" });
  }
  return { repo: true, branch: branch.stdout.trim(), files };
}

/** Unified diff for one file (untracked files render as all-additions). */
export async function diff(cwd, file) {
  if (!(await isRepo(cwd))) return "";
  let rel = null;
  if (file) {
    rel = confine(cwd, file);
    if (!rel) return "";        // outside the repo, or option-shaped
  }
  // Every git invocation puts the path after a `--` separator, or a value like
  // "--output=/path" is parsed as an OPTION and git truncates that file while parsing,
  // before it even validates the arguments.
  const target = rel ? ["--", rel] : [];
  let out = (await run(["diff", "--no-color", "HEAD", ...target], cwd)).stdout;
  // Nothing tracked to show: it may be a new file, which renders as all-additions.
  if (!out && rel) {
    out = (await run(["diff", "--no-color", "--no-index", "--", "/dev/null", rel], cwd)).stdout;
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

/** Destructive: reverts tracked files (staged included) and removes untracked ones. */
export async function discard(cwd) {
  if (!(await isRepo(cwd))) return { ok: false, error: "not a git repository" };
  // `checkout -- .` copies the INDEX back over the worktree, so anything staged
  // survived it untouched while the phone was told the discard worked. commit() runs
  // `git add -A` first, so a rejected commit leaves the whole tree staged: you tapped
  // Discard, believed it, and the next commit swept the "discarded" work into history.
  const revert = await run(["reset", "--hard", "HEAD"], cwd);
  const clean = await run(["clean", "-fd"], cwd);
  // Report success only if the tree is actually clean afterwards.
  const left = await run(["status", "--porcelain", "-z"], cwd);
  const dirty = left.ok && left.stdout.split("\0").filter(Boolean).length > 0;
  return {
    ok: revert.ok && clean.ok && !dirty,
    error: dirty ? "some changes could not be discarded" : undefined,
    output: [revert.stdout, clean.stdout].filter(Boolean).join("\n").trim(),
  };
}
