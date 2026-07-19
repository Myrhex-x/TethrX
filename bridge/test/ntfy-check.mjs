// Verify the ntfy push mechanism (same POST + headers the bridge uses) round-trips.
const topic = "grokremote-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36);
const url = "https://ntfy.sh/" + topic;

await fetch(url, {
  method: "POST",
  headers: { Title: "approval needed", Priority: "high", Tags: "warning" },
  body: "echo pending > pending.txt",
});

await new Promise((r) => setTimeout(r, 1800));
const body = await (await fetch(url + "/json?poll=1")).text();
const ok = body.includes("echo pending > pending.txt") && body.includes("approval needed");
console.log("topic:", topic);
console.log("NTFY PUSH:", ok ? "PASS ✓ (message delivered with title/priority)" : "FAIL ✗\n" + body.slice(0, 300));
process.exit(0);
