// Install the bridge as a background service, so it survives closing the terminal
// and starts itself again after a reboot.
//
// Without this the bridge only lives as long as the terminal window that launched
// it — which quietly breaks the product's core promise ("works as long as your
// computer is on"), usually at the worst moment: you're out, you send a message,
// and nothing answers because a laptop rebooted for an update.
//
//   tethrx-bridge service install [--host 0.0.0.0] [--port 4180]
//   tethrx-bridge service status
//   tethrx-bridge service logs [-n 80]
//   tethrx-bridge service restart
//   tethrx-bridge service uninstall
//
// macOS gets a LaunchAgent, Linux a systemd --user unit. Both run as the logged-in
// user (never root): the bridge drives that user's own Grok install and needs their
// HOME, their PATH, and their file permissions — nothing more.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { config } from "./config.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SERVER = join(__dirname, "server.mjs");
const LABEL = "com.tethrx.bridge";
const LOG_DIR = join(config.stateDir, "logs");
const OUT_LOG = join(LOG_DIR, "bridge.out.log");
const ERR_LOG = join(LOG_DIR, "bridge.err.log");

const PLIST = join(homedir(), "Library", "LaunchAgents", `${LABEL}.plist`);
const UNIT = join(homedir(), ".config", "systemd", "user", "tethrx-bridge.service");

// Labels this project has used before. An early hand-written agent under the old
// "grok-remote" name is still out there on machines that ran the bridge before it
// was called TethrX; two agents fighting over one port is a confusing failure, so
// a stale one gets cleared — but only when it is genuinely holding the port we want.
const LEGACY_LABELS = ["com.grokremote.bridge"];

// Settings the service must remember. A service installed from a shell that had
// GROK_REMOTE_HOST=0.0.0.0 set has to keep that after a reboot, when no shell is
// involved at all — so they are baked into the plist / unit file.
const PASSTHROUGH = [
  "GROK_REMOTE_HOST", "GROK_REMOTE_PORT", "GROK_REMOTE_CWD", "GROK_REMOTE_MODEL",
  "GROK_REMOTE_TRANSPORT", "GROK_REMOTE_ASK", "GROK_REMOTE_NTFY", "GROK_REMOTE_PUBLIC_URL",
  "GROK_REMOTE_PERMISSION_MODE", "GROK_REMOTE_TLS_CERT", "GROK_REMOTE_TLS_KEY",
  "GROK_REMOTE_TLS_PORT", "GROK_BIN",
];

function run(cmd, args, { quiet = true } = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", stdio: quiet ? "pipe" : "inherit" });
  return { ok: r.status === 0, out: (r.stdout || "") + (r.stderr || ""), status: r.status };
}

/** launchd and systemd both start with a bare PATH, so `grok` has to be findable
 *  by absolute location. Put node's own directory and grok's install dir up front. */
function servicePath() {
  const parts = [dirname(process.execPath), join(homedir(), ".grok", "bin")];
  if (config.grokBin.includes("/")) parts.push(dirname(config.grokBin));
  parts.push("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin");
  return [...new Set(parts)].join(":");
}

function envForService(overrides) {
  const env = { PATH: servicePath(), HOME: homedir() };
  for (const key of PASSTHROUGH) {
    if (process.env[key]) env[key] = process.env[key];
  }
  Object.assign(env, overrides);
  return env;
}

function xmlEscape(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function plistXML(env) {
  const envEntries = Object.entries(env)
    .map(([k, v]) => `      <key>${xmlEscape(k)}</key>\n      <string>${xmlEscape(v)}</string>`)
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(process.execPath)}</string>
    <string>${xmlEscape(SERVER)}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
${envEntries}
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <!-- Restart if it crashes, but honour a deliberate stop (the bridge exits 0 on
       SIGTERM), so \`service restart\` and \`service uninstall\` behave. -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>WorkingDirectory</key>
  <string>${xmlEscape(homedir())}</string>
  <key>StandardOutPath</key>
  <string>${xmlEscape(OUT_LOG)}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(ERR_LOG)}</string>
</dict>
</plist>
`;
}

function unitFile(env) {
  const environment = Object.entries(env)
    .map(([k, v]) => `Environment=${k}=${v}`)
    .join("\n");
  return `[Unit]
Description=TethrX bridge (Grok Build, reachable from your phone)
After=network-online.target

[Service]
Type=simple
ExecStart=${process.execPath} ${SERVER}
WorkingDirectory=${homedir()}
${environment}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
`;
}

// --- port probe --------------------------------------------------------------

/** Is something already answering as a bridge on this port? Installing a service
 *  while a terminal copy holds the port produces a service that can never bind,
 *  and a confusing "it's installed but dead" state. */
async function probe(port) {
  try {
    const r = await fetch(`http://127.0.0.1:${port}/api/health`, { signal: AbortSignal.timeout(1200) });
    if (!r.ok) return null;
    return await r.json();
  } catch {
    return null;
  }
}

/** Unload + delete this project's older launch agents. Returns the labels removed. */
function removeLegacyAgents() {
  const removed = [];
  for (const label of LEGACY_LABELS) {
    const path = join(homedir(), "Library", "LaunchAgents", `${label}.plist`);
    if (!existsSync(path)) continue;
    run("launchctl", ["bootout", `gui/${userInfo().uid}/${label}`]);
    run("launchctl", ["unload", "-w", path]);
    try { rmSync(path, { force: true }); removed.push(label); } catch { /* leave it */ }
  }
  return removed;
}

// --- commands ----------------------------------------------------------------

function parseFlags(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--host" && argv[i + 1]) out.host = argv[++i];
    else if (argv[i] === "--port" && argv[i + 1]) out.port = argv[++i];
    else if ((argv[i] === "-n" || argv[i] === "--lines") && argv[i + 1]) out.lines = Number(argv[++i]);
  }
  return out;
}

const isMac = process.platform === "darwin";
const isLinux = process.platform === "linux";

async function install(flags) {
  const host = flags.host || process.env.GROK_REMOTE_HOST || config.host;
  const port = String(flags.port || config.port);
  const overrides = { GROK_REMOTE_HOST: host, GROK_REMOTE_PORT: port };
  const env = envForService(overrides);

  let running = await probe(Number(port));
  let replaced = [];
  if (running && isMac) {
    // Something answers on this port. If it's one of this project's own older agents,
    // it IS the thing being replaced — clear it and take the port over.
    replaced = removeLegacyAgents();
    if (replaced.length) {
      await new Promise((r) => setTimeout(r, 1200));   // let the port come free
      running = await probe(Number(port));
    }
  }
  if (running) {
    console.log(`\n  A bridge is already running on port ${port}.`);
    console.log("  Stop it first (Ctrl+C in its terminal), then run this again.");
    console.log(`  Or install this service on a different port:  --port ${Number(port) + 2}\n`);
    return 1;
  }

  mkdirSync(LOG_DIR, { recursive: true });

  if (isMac) {
    mkdirSync(dirname(PLIST), { recursive: true });
    writeFileSync(PLIST, plistXML(env));
    const domain = `gui/${userInfo().uid}`;
    run("launchctl", ["bootout", `${domain}/${LABEL}`]);          // clear any previous copy
    let r = run("launchctl", ["bootstrap", domain, PLIST]);
    if (!r.ok) r = run("launchctl", ["load", "-w", PLIST]);       // older macOS
    if (!r.ok) {
      console.log(`\n  Couldn't start the service: ${r.out.trim() || "launchctl refused"}\n`);
      return 1;
    }
  } else if (isLinux) {
    mkdirSync(dirname(UNIT), { recursive: true });
    writeFileSync(UNIT, unitFile(env));
    run("systemctl", ["--user", "daemon-reload"]);
    const r = run("systemctl", ["--user", "enable", "--now", "tethrx-bridge"]);
    if (!r.ok) {
      console.log(`\n  Couldn't start the service: ${r.out.trim() || "systemctl refused"}\n`);
      return 1;
    }
  } else {
    console.log(`\n  Background service install isn't supported on ${process.platform} yet.`);
    console.log("  Keep running `npx tethrx-bridge` in a terminal window instead.\n");
    return 1;
  }

  // Give it a moment to bind, then confirm rather than claiming success blindly.
  let health = null;
  for (let i = 0; i < 10 && !health; i++) {
    await new Promise((r) => setTimeout(r, 400));
    health = await probe(Number(port));
  }

  console.log("\n  TethrX bridge installed as a background service.");
  if (replaced.length) console.log(`  ├─ replaced    an older bridge service (${replaced.join(", ")})`);
  console.log(`  ├─ starts automatically when you log in, and restarts if it crashes`);
  console.log(`  ├─ listening   ${host}:${port}${health ? "" : "   (not answering yet — see logs below)"}`);
  console.log(`  ├─ logs        ${OUT_LOG}`);
  console.log(`  └─ manage      tethrx-bridge service status | logs | restart | uninstall`);

  if (["127.0.0.1", "::1", "localhost"].includes(String(host))) {
    console.log("\n  NOTE: this service only listens on this computer, so your phone cannot reach it.");
    console.log("  Reinstall it reachable with:\n");
    console.log("      tethrx-bridge service install --host 0.0.0.0\n");
    console.log("  Only do that on a network you trust — the pairing token is what protects the bridge.");
  }
  if (isLinux) {
    console.log("\n  To keep it running when you're logged out:  loginctl enable-linger $USER");
  }
  if (!health) {
    console.log(`\n  It hasn't answered yet. Check ${ERR_LOG} — or run: tethrx-bridge service logs`);
  }
  console.log("");
  return 0;
}

function uninstall() {
  if (isMac) {
    run("launchctl", ["bootout", `gui/${userInfo().uid}/${LABEL}`]);
    run("launchctl", ["unload", "-w", PLIST]);
    if (existsSync(PLIST)) rmSync(PLIST, { force: true });
  } else if (isLinux) {
    run("systemctl", ["--user", "disable", "--now", "tethrx-bridge"]);
    if (existsSync(UNIT)) rmSync(UNIT, { force: true });
    run("systemctl", ["--user", "daemon-reload"]);
  } else {
    console.log(`\n  Nothing to uninstall on ${process.platform}.\n`);
    return 1;
  }
  console.log("\n  Background service removed. Sessions and pairing are untouched.");
  console.log("  Start the bridge by hand any time with: npx tethrx-bridge\n");
  return 0;
}

function restart() {
  if (isMac) {
    const r = run("launchctl", ["kickstart", "-k", `gui/${userInfo().uid}/${LABEL}`]);
    if (!r.ok) { console.log(`\n  Couldn't restart it: ${r.out.trim()}\n`); return 1; }
  } else if (isLinux) {
    const r = run("systemctl", ["--user", "restart", "tethrx-bridge"]);
    if (!r.ok) { console.log(`\n  Couldn't restart it: ${r.out.trim()}\n`); return 1; }
  } else {
    return 1;
  }
  console.log("\n  Bridge restarted.\n");
  return 0;
}

async function status() {
  const installed = isMac ? existsSync(PLIST) : isLinux ? existsSync(UNIT) : false;
  let loaded = false;
  if (isMac && installed) loaded = run("launchctl", ["print", `gui/${userInfo().uid}/${LABEL}`]).ok;
  if (isLinux && installed) loaded = run("systemctl", ["--user", "is-active", "tethrx-bridge"]).out.trim() === "active";

  const health = await probe(config.port);

  console.log("\n  TethrX bridge service");
  console.log(`  ├─ installed   ${installed ? "yes" : "no"}${installed ? `  (${isMac ? PLIST : UNIT})` : ""}`);
  console.log(`  ├─ loaded      ${loaded ? "yes" : "no"}`);
  console.log(`  ├─ answering   ${health ? `yes  (v${health.version || "?"} on port ${config.port})` : `no   (nothing on port ${config.port})`}`);
  if (health) console.log(`  ├─ grok        ${health.grok || "NOT FOUND — the service can't see the grok binary"}`);
  console.log(`  └─ logs        ${OUT_LOG}`);
  if (!installed) console.log("\n  Install it with: tethrx-bridge service install --host 0.0.0.0");
  else if (!health) console.log("\n  Installed but not answering. Check: tethrx-bridge service logs");
  console.log("");
  return 0;
}

function logs(flags) {
  const n = Number.isFinite(flags.lines) ? flags.lines : 60;
  for (const [name, path] of [["output", OUT_LOG], ["errors", ERR_LOG]]) {
    if (!existsSync(path)) continue;
    let text = "";
    try { text = readFileSync(path, "utf8"); } catch { continue; }
    const lines = text.split("\n").filter(Boolean).slice(-n);
    if (!lines.length) continue;
    console.log(`\n  ── ${name} (${path}) ──\n`);
    // A service writes its startup banner — pairing token and all — straight into
    // this file. These lines get pasted into bug reports, so strip it on the way out.
    for (const l of lines) {
      console.log("  " + (config.token ? l.split(config.token).join("<pairing token hidden>") : l));
    }
  }
  if (!existsSync(OUT_LOG) && !existsSync(ERR_LOG)) {
    console.log("\n  No service logs yet — is it installed? Try: tethrx-bridge service status\n");
  } else {
    console.log("");
  }
  return 0;
}

function usage() {
  console.log(`
  Run the TethrX bridge in the background, starting automatically at login.

    tethrx-bridge service install [--host 0.0.0.0] [--port 4180]
    tethrx-bridge service status
    tethrx-bridge service logs [-n 80]
    tethrx-bridge service restart
    tethrx-bridge service uninstall
`);
  return 1;
}

/** Handle `tethrx-bridge service …`. Returns a process exit code. */
export async function runServiceCommand(argv) {
  const [sub, ...rest] = argv;
  const flags = parseFlags(rest);
  switch (sub) {
    case "install": return await install(flags);
    case "uninstall": case "remove": return uninstall();
    case "restart": return restart();
    case "status": return await status();
    case "logs": return logs(flags);
    default: return usage();
  }
}
