// Verify rename (PATCH) and delete (DELETE) endpoints.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const base = "http://127.0.0.1:4180";
const token = JSON.parse(readFileSync(join(homedir(), ".grok-remote", "config.json"), "utf8")).token;
const H = { authorization: "Bearer " + token, "content-type": "application/json" };

const s = await (await fetch(base + "/api/sessions", { method: "POST", headers: H, body: JSON.stringify({ cwd: "/tmp", title: "todelete" }) })).json();

const renamed = await (await fetch(base + "/api/sessions/" + s.id, { method: "PATCH", headers: H, body: JSON.stringify({ title: "renamed-ok" }) })).json();
console.log("RENAME:", renamed.title === "renamed-ok" ? "PASS ✓" : "FAIL ✗ (" + renamed.title + ")");

await fetch(base + "/api/sessions/" + s.id, { method: "DELETE", headers: H });
const after = await fetch(base + "/api/sessions/" + s.id, { headers: H });
console.log("DELETE:", after.status === 404 ? "PASS ✓ (gone)" : "FAIL ✗ (status " + after.status + ")");
process.exit(0);
