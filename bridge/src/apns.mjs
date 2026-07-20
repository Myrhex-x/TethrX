// Native push to the phone via Apple Push Notification service (APNs).
//
// Zero-dependency: signs the APNs provider JWT (ES256) with node:crypto and posts
// over node:http2. Disabled unless an APNs auth key (.p8) + Key ID + Team ID are
// configured — otherwise the bridge falls back to ntfy / nothing.

import http2 from "node:http2";
import { createSign } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const b64url = (x) => Buffer.from(x).toString("base64url");

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
  }

  _load() {
    try {
      const d = JSON.parse(readFileSync(this.devicesPath, "utf8"));
      return Array.isArray(d.tokens) ? d.tokens : [];
    } catch { return []; }
  }
  _save() {
    try { writeFileSync(this.devicesPath, JSON.stringify({ tokens: this.tokens }, null, 2), { mode: 0o600 }); }
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
    try { writeFileSync(this.laPath, JSON.stringify(this.la, null, 2), { mode: 0o600 }); }
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
    try { jwt = this._providerToken(); } catch { return { status: 0 }; }
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
        let status = 0, body = "";
        req.setEncoding("utf8");
        req.on("response", (h) => { status = h[":status"]; });
        req.on("data", (d) => { body += d; });
        req.on("end", () => resolve({ status, body }));
        req.on("error", () => resolve({ status: 0, body: "" }));
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
      "content-state": contentState,
      alert: { title: alertTitle || "", body: alertBody || "" },
    };
    const results = await Promise.all(this.la.startTokens.map((t) => this._sendLa(t, aps)));
    const dead = new Set();
    results.forEach((r, i) => {
      if (r.status === 410 || /BadDeviceToken|Unregistered/.test(r.body || "")) dead.add(this.la.startTokens[i]);
    });
    if (dead.size) { this.la.startTokens = this.la.startTokens.filter((t) => !dead.has(t)); this._saveLa(); }
  }

  /** Update the live activity of one session (no-op without its update token). */
  async laUpdate(sessionId, contentState) {
    const token = this.la.sessions[sessionId];
    if (!token) return;
    await this._sendLa(token, {
      timestamp: Math.floor(Date.now() / 1000),
      event: "update",
      "content-state": contentState,
    });
  }

  /** End the session's live activity and forget its token. */
  async laEnd(sessionId, contentState) {
    const token = this.la.sessions[sessionId];
    if (!token) return;
    await this._sendLa(token, {
      timestamp: Math.floor(Date.now() / 1000),
      event: "end",
      "content-state": contentState,
      "dismissal-date": Math.floor(Date.now() / 1000) + 180,
    });
    this.clearLaSession(sessionId);
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
      let status = 0, body = "";
      req.setEncoding("utf8");
      req.on("response", (h) => { status = h[":status"]; });
      req.on("data", (d) => { body += d; });
      req.on("end", () => resolve({ token, status, body }));
      req.on("error", () => resolve({ token, status: 0, body: "" }));
      req.end(payloadStr);
    });
  }

  /** Deliver an alert to every registered device; prune tokens APNs reports dead.
   *  `category` drives the notification's action buttons on the phone; the request /
   *  option ids let it approve or reject a tool right from the notification. */
  async send({ title, body, sessionId, category, requestId, allowOptionId, rejectOptionId }) {
    if (!this.enabled || this.tokens.length === 0) return;
    let jwt;
    try { jwt = this._providerToken(); } catch { return; }
    const payloadStr = JSON.stringify({
      aps: {
        alert: { title, body },
        sound: "default",
        "thread-id": sessionId || "",
        ...(category ? { category } : {}),
      },
      sessionId: sessionId || "",
      ...(requestId ? { requestId } : {}),
      ...(allowOptionId ? { allowOptionId } : {}),
      ...(rejectOptionId ? { rejectOptionId } : {}),
    });
    const client = http2.connect("https://api.push.apple.com");
    client.on("error", () => {});
    try {
      const results = await Promise.all(this.tokens.map((t) => this._sendOne(client, t, payloadStr, jwt)));
      const dead = new Set(
        results.filter((r) => r.status === 410 || /BadDeviceToken|Unregistered/.test(r.body)).map((r) => r.token)
      );
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
