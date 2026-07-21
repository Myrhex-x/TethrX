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

- **Stronger option (recommended, one day of work): a built-in demo mode** — a
  "Try the demo" button on the pairing screen backed by canned session data, so
  a reviewer can experience the app with zero hardware. This also helps every
  curious person who downloads the app before installing the bridge.

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

- Demo mode (above).
- Accessibility pass: the app uses fixed font sizes, so Dynamic Type currently
  does nothing; VoiceOver labels exist for icon buttons but a full pass is due.
- Widget-target `PrivacyInfo.xcprivacy` (the widget reads UserDefaults via the
  App Group): the app-level manifest covers review today, a per-target copy is
  belt and braces.
- Localization (French first) if you want featured placement in FR.
