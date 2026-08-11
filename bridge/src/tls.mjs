// Self-signed TLS for the bridge, pinned by the app.
//
// The bridge speaks HTTPS on a second port with a certificate it mints once via
// the system `openssl` (ships with macOS and every Linux). There's no CA and no
// hostname to validate — the phone learns the certificate's SHA-256 fingerprint
// out-of-band (the pairing QR) and pins exactly that cert, which is stronger
// than web PKI for a two-party setup and needs no cert warnings anywhere.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, chmodSync } from "node:fs";
import { join } from "node:path";

// Ten years. Nothing warns anyone when a pinned self-signed cert expires: every
// paired phone simply stops connecting, looking exactly like a bridge that died,
// and the only cure is re-pairing. So outlive the install rather than the year.
const CERT_DAYS = "3650";

/** Ensure a keypair + cert exist; return { cert, key, fingerprint } or null. */
export function ensureTls(stateDir) {
  const dir = join(stateDir, "tls");
  const certPath = join(dir, "cert.pem");
  const keyPath = join(dir, "key.pem");
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const haveCert = existsSync(certPath);
    const haveKey = existsSync(keyPath);
    // Half a pair can't serve HTTPS, so it has to be re-minted — but that changes
    // the fingerprint, and every phone that pinned the old one then fails the
    // handshake with nothing on screen to explain it. This used to be one OR over
    // both files, so losing key.pem rotated the identity in silence. Say it out loud.
    if (haveCert !== haveKey) {
      console.error(`[bridge] TLS ${haveKey ? "certificate" : "key"} is missing, so a new certificate was created.`);
      console.error("[bridge] the certificate changed: re-pair your phone (scan the pairing QR again).");
    }
    if (!haveCert || !haveKey) {
      // openssl creates key.pem under the process umask, which leaves it briefly
      // world-readable (0644 under the usual 022) before the chmod below lands.
      const prevMask = process.umask(0o077);
      try {
        execFileSync("openssl", [
          "req", "-x509", "-newkey", "rsa:2048",
          "-keyout", keyPath, "-out", certPath,
          "-days", CERT_DAYS, "-nodes", "-subj", "/CN=TethrX bridge",
        ], { stdio: "ignore" });
      } finally { process.umask(prevMask); }
      chmodSync(keyPath, 0o600);
    }
    const certPem = readFileSync(certPath, "utf8");
    const key = readFileSync(keyPath, "utf8");
    // Fingerprint = SHA-256 of the DER certificate — what the app compares
    // against the leaf it receives during the handshake.
    const b64 = certPem.replace(/-----(BEGIN|END) CERTIFICATE-----|\s+/g, "");
    const fingerprint = createHash("sha256").update(Buffer.from(b64, "base64")).digest("hex");
    return { cert: certPem, key, fingerprint };
  } catch {
    return null;   // no openssl (or unwritable state dir) — bridge stays HTTP-only
  }
}
