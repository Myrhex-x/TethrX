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

/** Ensure a keypair + cert exist; return { cert, key, fingerprint } or null. */
export function ensureTls(stateDir) {
  const dir = join(stateDir, "tls");
  const certPath = join(dir, "cert.pem");
  const keyPath = join(dir, "key.pem");
  try {
    mkdirSync(dir, { recursive: true });
    if (!existsSync(certPath) || !existsSync(keyPath)) {
      execFileSync("openssl", [
        "req", "-x509", "-newkey", "rsa:2048",
        "-keyout", keyPath, "-out", certPath,
        "-days", "3650", "-nodes", "-subj", "/CN=TethrX bridge",
      ], { stdio: "ignore" });
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
