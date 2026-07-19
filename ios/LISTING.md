# App Store Connect listing — TethrX

**App name:** TethrX
**Subtitle (≤30):** Remote for Grok Build
**Category:** Developer Tools
**Bundle ID:** com.tethrx.app
**Price:** Free

**Promotional text (≤170):**
> Drive Grok Build from your phone — watch it work tool-by-tool, review its plans, and approve or reject each action, even from your lock screen.

**Keywords (≤100):**
> grok,grok build,remote,terminal,coding agent,developer,cli,ssh,ai,pair,tailscale,agent

**Description:**
> TethrX is a native, private remote for **Grok Build**, xAI's terminal coding agent. Your phone is only a control plane — Grok, its tools, and your code stay on your own machine. TethrX connects to a small open-source bridge you run on your computer.
>
> • Watch Grok work in real time — thoughts, commands, file edits, and their output.
> • Approve or reject every tool call — from the app, or straight from a push notification on your lock screen.
> • Plan mode — Grok drafts a plan; you review and approve it before it builds.
> • Open, follow, rename, and delete sessions; context resumes across restarts.
> • No accounts, no tracking, no third-party servers. Your phone talks only to your bridge (direct, over Tailscale, or via TLS).
>
> Requires your own Grok Build install (SuperGrok / X Premium Plus) and the TethrX bridge running on your computer. Setup takes a couple of minutes.
>
> TethrX is an independent client and is not affiliated with, endorsed by, or sponsored by xAI. "Grok" and "Grok Build" are trademarks of their respective owner.

**Privacy — Data collection:** None. (Nothing is collected; the app communicates only with the user's self-hosted bridge.)

**Export compliance:** Uses only standard/exempt encryption (HTTPS/TLS). `ITSAppUsesNonExemptEncryption = false` is set in Info.plist, so no CCATS/year-end docs are required.

**"What to test" (TestFlight notes to testers):**
> You'll need Grok Build installed on your Mac/Linux box and the TethrX bridge running (`node bridge/src/server.mjs`). Enter the address + pairing token it prints, then start a session. Try plan mode and approving/rejecting a shell command.

**URLs (fill in before submitting):**
- Support URL: _your site or a GitHub repo_
- Marketing URL (optional): _your site_
- Privacy Policy URL: _required — a simple page stating "no data collected"_
