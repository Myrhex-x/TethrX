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

  /** Deliver an alert to every registered device; prune tokens APNs reports dead. */
  async send({ title, body, sessionId }) {
    if (!this.enabled || this.tokens.length === 0) return;
    let jwt;
    try { jwt = this._providerToken(); } catch { return; }
    const payloadStr = JSON.stringify({
      aps: { alert: { title, body }, sound: "default", "thread-id": sessionId || "" },
      sessionId: sessionId || "",
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
