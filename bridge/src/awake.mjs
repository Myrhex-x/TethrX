// Keep the computer awake while a Grok turn is running.
//
// Without this, a laptop that idles (or has its lid closed) sleeps mid-task and the
// turn dies — which breaks the app's core promise of "works as long as your computer
// is on". We hold a `caffeinate` child process for as long as at least one turn is in
// flight, and let it go the moment everything is idle. macOS only; a no-op elsewhere.

import { spawn } from "node:child_process";

let proc = null;
let holders = 0;

/** Mark a turn as started; spawns caffeinate on the first holder. */
export function acquire() {
  holders += 1;
  if (proc || process.platform !== "darwin") return;
  try {
    // -i no idle sleep, -m no disk sleep, -s no system sleep (while on AC).
    // -w <our pid> makes caffeinate exit if the bridge is killed, rather than
    // surviving as an orphan that keeps the machine awake indefinitely.
    const child = spawn("/usr/bin/caffeinate", ["-i", "-m", "-s", "-w", String(process.pid)], { stdio: "ignore" });
    proc = child;
    // Only ever forget THIS child. A turn that ends as the next one starts (a queued
    // follow-up, an approved plan) kills one caffeinate and spawns another in the
    // same tick; the old one's exit arrives later and used to null the new one, which
    // then could never be killed and kept the Mac awake for as long as the bridge ran.
    const forget = () => { if (proc === child) proc = null; };
    child.on("exit", forget);
    child.on("error", forget);
  } catch {
    proc = null;
  }
}

/** Mark a turn as finished; releases the assertion when the last holder goes. */
export function release() {
  holders = Math.max(0, holders - 1);
  if (holders === 0 && proc) {
    try { proc.kill(); } catch { /* already gone */ }
    proc = null;
  }
}

export function held() { return holders > 0 && Boolean(proc); }
