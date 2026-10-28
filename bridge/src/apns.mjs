// Native push to the phone via Apple Push Notification service (APNs).
//
// Zero-dependency: signs the APNs provider JWT (ES256) with node:crypto and posts
// over node:http2. Disabled unless an APNs auth key (.p8) + Key ID + Team ID are
// configured — otherwise the bridge falls back to ntfy / nothing.

import http2 from "node:http2";
import { createSign } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { writeAtomic } from "./sessions.mjs";
import { join } from "node:path";

const b64url = (x) => Buffer.from(x).toString("base64url");

// APNs occasionally accepts a stream and then never answers it (a half-open socket
// after the laptop wakes is the usual way). Without a deadline that promise never
// settles: the send stalls forever and takes the token pruning with it.
const REQUEST_TIMEOUT_MS = 10_000;

/** APNs refuses a payload over 4 KB outright, and a refused alert simply never arrives:
 *  an approval for a long heredoc used to be the one alert that never came. */
const MAX_PAYLOAD_BYTES = 4096;

/** At most `max` characters, with an ellipsis when anything was cut. Counts code
 *  points, so an emoji is never split in half. */
export function clipText(text, max) {
  const chars = Array.from(String(text ?? ""));
  return chars.length <= max ? chars.join("") : chars.slice(0, Math.max(0, max - 1)).join("") + "\u2026";
}

/** One line for a lock-screen card: whitespace and line breaks collapsed, then cut. */
export function oneLine(text, max = 120) {
  return clipText(String(text ?? "").replace(/\s+/g, " ").trim(), max);
}

/** A Live Activity state with its text sized for a lock screen and a 4 KB push. */
function fitContentState(state = {}) {
  return { ...state, ...(state.detail !== undefined ? { detail: oneLine(state.detail, 120) } : {}) };
}

export class Apns {
  constructor({ stateDir, keyPath, keyId, teamId, topic }) {
    this.devicesPath = join(stateDir, "devices.json");
    this.laPath = join(stateDir, "live-activity.json");
    this.keyId = keyId;
    this.teamId = teamId;
    this.topic = topic || "com.tethrx.app";
    this.keyPem = "";
    this.enabled = false;
    try {
      if (keyPath && keyId && teamId && existsSync(keyPath)) {
        this.keyPem = readFileSync(keyPath, "utf8");
        this.enabled = true;
      }
    } catch { /* leave disabled */ }
    this.tokens = this._load();
    // Live Activity push state: push-to-start tokens (per phone) + one update
    // token per session with a live activity.
    this.la = this._loadLa();
    this._jwt = null;
    this._jwtAt = 0;
    this._loggedFailures = new Set();
  }

  /** Say a push failed, once per distinct reason. A wrong Team ID or Key ID fails
   *  every push the same way forever, so logging per push would bury the machine —
   *  but logging nothing (what this used to do) leaves a bridge that pushes nothing
   *  and explains nothing, which is indistinguishable from "APNs is off". */
  _logOnce(key, message) {
    if (this._loggedFailures.has(key)) return;
    this._loggedFailures.add(key);
    console.error(`[apns] ${message}`);
  }

  _noteFailure(status, body, transport) {
    if (status >= 200 && status < 300) return;
    if (status === 410) return;                 // expected: the token is pruned below
    let reason = "";
    try { reason = JSON.parse(body || "{}").reason || ""; } catch { /* not JSON */ }
    const what = status ? `HTTP ${status}${reason ? ` ${reason}` : ""}` : (transport || "no response");
    this._logOnce(status ? `${status}:${reason}` : `transport:${transport || "?"}`,
      `push failed: ${what} (repeats of this are not logged)`);
  }

  /** Apple has retired this token: the app was deleted, or the activity is gone. */
  static _isDead(r) {
    return r.status === 410 || /BadDeviceToken|Unregistered/.test(r.body || "");
  }

  _load() {
    try {
      const d = JSON.parse(readFileSync(this.devicesPath, "utf8"));
      return Array.isArray(d.tokens) ? d.tokens : [];
    } catch { return []; }
  }
  _save() {
    try { writeAtomic(this.devicesPath, JSON.stringify({ tokens: this.tokens }, null, 2)); }
    catch { /* best-effort */ }
  }

  /** Register a phone's APNs device token (hex). Returns false if malformed. */
  addDevice(token) {
    if (typeof token !== "string" || !/^[0-9a-fA-F]{40,256}$/.test(token)) return false;
    const t = token.toLowerCase();
    if (!this.tokens.includes(t)) { this.tokens.push(t); this._save(); }
    return true;
  }

  _loadLa() {
    try {
      const d = JSON.parse(readFileSync(this.laPath, "utf8"));
      return { startTokens: Array.isArray(d.startTokens) ? d.startTokens : [], sessions: d.sessions || {} };
    } catch { return { startTokens: [], sessions: {} }; }
  }
  _saveLa() {
    try { writeAtomic(this.laPath, JSON.stringify(this.la, null, 2)); }
    catch { /* best-effort */ }
  }

  static _laTokenOk(token) {
    return typeof token === "string" && /^[0-9a-fA-F]{40,512}$/.test(token);
  }

  /** A phone's ActivityKit push-to-start token (lets the bridge START an activity). */
  addLaStartToken(token) {
    if (!Apns._laTokenOk(token)) return false;
    const t = token.toLowerCase();
    if (!this.la.startTokens.includes(t)) { this.la.startTokens.push(t); this._saveLa(); }
    return true;
  }

  /** The update token of a session's live activity (lets the bridge update/end it). */
  setLaUpdateToken(sessionId, token) {
    if (!sessionId || !Apns._laTokenOk(token)) return false;
    this.la.sessions[sessionId] = token.toLowerCase();
    this._saveLa();
    return true;
  }

  hasLaUpdateToken(sessionId) { return Boolean(this.la.sessions[sessionId]); }
  get hasLaStartTokens() { return this.la.startTokens.length > 0; }

  clearLaSession(sessionId) {
    if (this.la.sessions[sessionId]) { delete this.la.sessions[sessionId]; this._saveLa(); }
  }

  /** One Live Activity push. `event`: "start" | "update" | "end". */
  async _sendLa(token, aps) {
    if (!this.enabled) return { status: 0 };
    let jwt;
    try { jwt = this._providerToken(); }
    catch (e) { this._logOnce("sign", `cannot sign the provider token, check the .p8 key: ${e.message}`); return { status: 0 }; }
    const payloadStr = JSON.stringify({ aps });
    const client = http2.connect("https://api.push.apple.com");
    client.on("error", () => {});
    try {
      return await new Promise((resolve) => {
        const req = client.request({
          ":method": "POST",
          ":path": `/3/device/${token}`,
          authorization: `bearer ${jwt}`,
          "apns-topic": `${this.topic}.push-type.liveactivity`,
          "apns-push-type": "liveactivity",
          "apns-priority": "10",
        });
        let status = 0, body = "", settled = false;
        const finish = (transport) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          this._noteFailure(status, body, transport);
          resolve({ status, body });
        };
        const timer = setTimeout(() => { try { req.destroy(); } catch { /* already gone */ } finish("timed out"); }, REQUEST_TIMEOUT_MS);
        req.setEncoding("utf8");
        req.on("response", (h) => { status = h[":status"]; });
        req.on("data", (d) => { body += d; });
        req.on("end", () => finish());
        req.on("error", () => finish("connection failed"));
        req.end(payloadStr);
      });
    } finally { try { client.close(); } catch { /* ignore */ } }
  }

  /** Start a Live Activity on every registered phone (app can be closed). */
  async laStart({ attributes, contentState, alertTitle, alertBody }) {
    if (!this.enabled || !this.la.startTokens.length) return;
    const aps = {
      timestamp: Math.floor(Date.now() / 1000),
      event: "start",
      "attributes-type": "TethrXActivityAttributes",
      attributes,
      "content-state": fitContentState(contentState),
      alert: { title: oneLine(alertTitle || "", 120), body: oneLine(alertBody || "", 200) },
    };
    const results = await Promise.all(this.la.startTokens.map((t) => this._sendLa(t, aps)));
    const dead = new Set();
    results.forEach((r, i) => {
      if (Apns._isDead(r)) dead.add(this.la.startTokens[i]);
    });
    if (dead.size) { this.la.startTokens = this.la.startTokens.filter((t) => !dead.has(t)); this._saveLa(); }
  }

  /** Update the live activity of one session (no-op without its update token). */
  async laUpdate(sessionId, contentState) {
    const token = this.la.sessions[sessionId];
    if (!token) return;
    const r = await this._sendLa(token, {
      timestamp: Math.floor(Date.now() / 1000),
      event: "update",
      "content-state": fitContentState(contentState),
    });
    // An activity's update token dies on its own (the user swiped it away, the app
    // was reinstalled). Keeping it meant every later update in the session kept
    // pushing at a token Apple had already told us was gone.
    if (Apns._isDead(r)) this.clearLaSession(sessionId);
  }

  /** End the session's live activity and forget its token. */
  async laEnd(sessionId, contentState) {
    const token = this.la.sessions[sessionId];
    if (!token) return;
    // Forget it BEFORE the push goes out. A queued follow-up or an approved plan starts
    // its turn in the same tick this one ends, and while the end was in flight that
    // turn found the old token, sent "working" to the card being ended, and so never
    // push-started a card of its own.
    this.clearLaSession(sessionId);
    await this._sendLa(token, {
      timestamp: Math.floor(Date.now() / 1000),
      event: "end",
      "content-state": fitContentState(contentState),
      "dismissal-date": Math.floor(Date.now() / 1000) + 180,
    });
  }

  /** Cached provider JWT (valid up to 1h; APNs rejects >1h and <20min-refreshed spam). */
  _providerToken() {
    const now = Math.floor(Date.now() / 1000);
    if (this._jwt && now - this._jwtAt < 2400) return this._jwt;   // reuse ~40 min
    const header = b64url(JSON.stringify({ alg: "ES256", kid: this.keyId }));
    const payload = b64url(JSON.stringify({ iss: this.teamId, iat: now }));
    const input = `${header}.${payload}`;
    // dsaEncoding ieee-p1363 -> raw r||s (JOSE), exactly what JWT ES256 wants.
    const sig = createSign("SHA256").update(input).sign({ key: this.keyPem, dsaEncoding: "ieee-p1363" });
    this._jwt = `${input}.${sig.toString("base64url")}`;
    this._jwtAt = now;
    return this._jwt;
  }

  _sendOne(client, token, payloadStr, jwt) {
    return new Promise((resolve) => {
      const req = client.request({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${jwt}`,
        "apns-topic": this.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
      });
      let status = 0, body = "", settled = false;
      const finish = (transport) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this._noteFailure(status, body, transport);
        resolve({ token, status, body });
      };
      const timer = setTimeout(() => { try { req.destroy(); } catch { /* already gone */ } finish("timed out"); }, REQUEST_TIMEOUT_MS);
      req.setEncoding("utf8");
      req.on("response", (h) => { status = h[":status"]; });
      req.on("data", (d) => { body += d; });
      req.on("end", () => finish());
      req.on("error", () => finish("connection failed"));
      req.end(payloadStr);
    });
  }

  /** Deliver an alert to every registered device; prune tokens APNs reports dead.
   *  `category` drives the notification's action buttons on the phone; the request /
   *  option ids let it approve or reject a tool right from the notification. */
  async send({ title, body, sessionId, category, requestId, allowOptionId, rejectOptionId }) {
    if (!this.enabled || this.tokens.length === 0) return;
    let jwt;
    try { jwt = this._providerToken(); }
    catch (e) { this._logOnce("sign", `cannot sign the provider token, check the .p8 key: ${e.message}`); return; }
    const build = (bodyText) => JSON.stringify({
      aps: {
        alert: { title: clipText(title, 120), body: bodyText },
        sound: "default",
        "thread-id": sessionId || "",
        ...(category ? { category } : {}),
      },
      sessionId: sessionId || "",
      ...(requestId ? { requestId } : {}),
      ...(allowOptionId ? { allowOptionId } : {}),
      ...(rejectOptionId ? { rejectOptionId } : {}),
    });
    // The body is what grows (a whole command, a whole summary). Cut it until the
    // payload fits: a notification with the start of a command beats none at all.
    let limit = 1000;
    let payloadStr = build(clipText(body, limit));
    while (Buffer.byteLength(payloadStr) > MAX_PAYLOAD_BYTES && limit > 40) {
      limit = Math.floor(limit / 2);
      payloadStr = build(clipText(body, limit));
    }
    const client = http2.connect("https://api.push.apple.com");
    client.on("error", () => {});
    try {
      const results = await Promise.all(this.tokens.map((t) => this._sendOne(client, t, payloadStr, jwt)));
      const dead = new Set(results.filter((r) => Apns._isDead(r)).map((r) => r.token));
      if (dead.size) { this.tokens = this.tokens.filter((t) => !dead.has(t)); this._save(); }
    } catch { /* best-effort */ }
    finally { try { client.close(); } catch { /* ignore */ } }
  }
}

export function loadApns(config) {
  const a = config.apns || {};
  return new Apns({
    stateDir: config.stateDir,
    keyPath: a.keyPath || process.env.GROK_REMOTE_APNS_KEY || "",
    keyId: a.keyId || process.env.GROK_REMOTE_APNS_KEY_ID || "",
    teamId: a.teamId || process.env.GROK_REMOTE_APNS_TEAM_ID || "",
    topic: a.topic || process.env.GROK_REMOTE_APNS_TOPIC || "com.tethrx.app",
  });
}
