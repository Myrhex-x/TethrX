# App Store submission checklist

Status audit for taking TethrX from TestFlight to the public App Store.
Verified items were checked against the project on 2026-07-21.

## Already in place (verified)

- **Privacy manifest** — `PrivacyInfo.xcprivacy`: no tracking, no data collection,
  UserDefaults declared with reason CA92.1.
- **Purpose strings** — camera (QR pairing), microphone + speech (dictation),
  local network (bridge), Face ID (app lock) all present in Info.plist.
- **`NSBonjourServices`** declared for `_tethrx._tcp` discovery.
- **Export compliance** — `ITSAppUsesNonExemptEncryption = false` (the app uses
  only standard TLS, which is exempt).
- **No deprecated or private APIs** (no UIWebView etc.).
- **Icon** — 1024px, no alpha (already accepted by TestFlight processing).
- **Unaffiliation disclaimer** — "independent, not affiliated with xAI" shown in
  the app (pairing footer, Settings) — keep it in the App Store description too.
- **Universal app** — iPhone + iPad layouts both real.
- **License / security policy** — Apache 2.0 LICENSE and SECURITY.md in the repo.
- **Privacy policy** — PRIVACY.md in the repo (see below for the URL step).
- **Share extension** (`TethrXShare`, build 35+) — sends the shared item to the
  user's own computer only, on an explicit tap. It reads the pairing token from a
  Keychain access group shared with the app; nothing is written to disk by the
  extension, and it collects nothing. No separate privacy label is needed: an app
  extension is covered by the containing app's answers.

## Must do before submitting (in App Store Connect)

1. **Privacy policy URL** — required field. Use
   `https://github.com/Myrhex-x/TethrX/blob/main/PRIVACY.md`
   (or a rendered page if you prefer).
2. **App Privacy questionnaire** — answer **"Data is not collected"** for every
   category. This matches the privacy manifest; do not guess extra categories,
   inconsistency between the label and the manifest causes rejections.
3. **App Review notes + demo video** (Guideline 2.1, the biggest risk — see below).
4. **iPad screenshots** — required now that the app is universal (13" iPad
   display size), plus the usual 6.9"/6.5" iPhone sets. Screenshot sessions
   pointed at a demo project folder, not your home directory.
5. **Age rating questionnaire** — all "None"; no unrestricted web access
   (the app has no browser). Expect 4+.
6. **EU trader status declaration (DSA)** — required for distribution in the EU.
   A free app with no monetization can generally declare non-trader; if you later
   charge, this becomes trader and requires published contact details.
7. **Category** — Developer Tools.
8. **Keychain sharing capability** — the app and share extension both carry
   `keychain-access-groups` (`$(AppIdentifierPrefix)group.com.tethrx.app`).
   Automatic signing provisioned this for build 35; if you ever move to manual
   profiles, the capability has to be enabled on both App IDs.

## Guideline 2.1 (App Completeness) — the main rejection risk

The reviewer has no Mac running the bridge, so the app they open stops at the
setup wizard. Standard practice for companion apps:

- Attach a **screen-recorded demo video** showing the full flow: bridge starting
  on a Mac, QR pairing, sending a task, approvals, git review.
- Paste review notes explaining the architecture. Draft:

> TethrX is a remote control for Grok Build (xAI's terminal coding agent)
> running on the user's own computer. The app requires a companion program —
> the open source bridge, https://github.com/Myrhex-x/TethrX — running on the
> reviewer's Mac, similar to how SSH clients require a server. The app operates
> no third-party server: the phone talks directly to the user's computer over
> the local network with certificate-pinned HTTPS, and the app collects no data.
> A demo video of the complete flow is attached. If a live test is required, the
> bridge can be started on any Mac with `npx tethrx-bridge` (Node 20+), and the
> app pairs by scanning the QR code it prints.

- **Demo mode is BUILT (build 32)** — "Try the demo" on the pairing screen loads
  canned sessions and a scripted conversation, so a reviewer can experience the
  full app with zero hardware. Mention it explicitly in the review notes:
  "A demo mode is available from the Try the demo button on the first screen."

## Known risks to keep an eye on

- **xAI trademark (Guideline 5.2)** — the app references Grok Build by name.
  Mitigations already in place: the app name/icon are TethrX's own, the
  unaffiliation disclaimer is everywhere, and no xAI logos or brand assets are
  used. Keep "Grok" out of the app NAME and subtitle brand position (fine to
  mention in the description factually: "a client for Grok Build"). If a 5.2
  rejection happens, the response is the disclaimer + nominative-use argument;
  the durable fix would be written permission from xAI.
- **Individual developer account** — the App Store listing will publicly show
  the personal name on the account. Converting to an organization (needs a
  D-U-N-S number) hides this behind a company name; decide before the public
  launch, since the seller name is visible to everyone.
- **Remote command execution** — precedent is firmly on our side (SSH clients:
  Termius, Blink, Prompt), and code runs on the user's own machine, not the
  phone. The review notes above frame it that way deliberately.

## Nice-to-have before a big public push

- ~~Demo mode~~ — built (build 32).
- ~~Accessibility~~ — Dynamic Type now scales all fonts (capped at the first
  accessibility size) and icon-only buttons carry VoiceOver labels (build 32).
- ~~Localization~~ — French ships in build 32; the per-app language picker
  appears automatically in iOS Settings → TethrX. A handful of dynamically
  composed strings remain English.
- Widget-target `PrivacyInfo.xcprivacy` (the widget reads UserDefaults via the
  App Group): the app-level manifest covers review today, a per-target copy is
  belt and braces.
