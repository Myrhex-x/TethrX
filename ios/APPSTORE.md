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

## Guideline 4.2.3(i) — REJECTED 2026-08-05, fixed in the build below

Submission `f6888598-bcb8-4cb1-869d-a23c19fcb695`, v1.0 (2), reviewed on an
iPhone 17 Pro Max:

> We were required to install Grok before we could use the app. Apps should be
> able to run on launch, without requiring additional apps to be installed.

**What the reviewer actually hit.** The app launched straight into the pairing
wizard, whose step 1 was titled *"Install Grok Build"* with a `curl … | bash`
command. Demo mode existed since build 32, but it was a 12pt dimmed text link in
the footer *below* the step card — walking the wizard top-down, you never see it
as a way to use the app.

**Fix (this build).** First run is no longer a setup checklist:

- **`WelcomeView` is the launch screen.** It fits on one screen with no
  scrolling, and nothing on it asks the user to install anything.
- **Prompt library — real standalone functionality.** Write, dictate, edit,
  search, copy, share and organise reusable task prompts, entirely on the phone,
  with no computer and no network. Persisted in `prompt.library` (UserDefaults
  JSON, migrating the old flat `prompt.snippets` list). The same prompts are the
  tappable chips above the chat composer once a computer *is* connected, so this
  is part of the product loop, not a stub bolted on for review.
- **"Take the tour" is the primary action** (filled pill, top of the screen),
  not a footer link. Same canned data as the old demo mode, renamed throughout
  (badge, Settings row, canned reply) so the vocabulary is consistent.
- **"Connect a computer" is a secondary action** that *pushes* the wizard, with
  the framing line "These steps all happen on the computer you want to control.
  Nothing extra is needed on this phone." Step 1 is retitled "Set up Grok Build
  on your computer".

**Point to make in the reply:** Grok Build is xAI's *terminal CLI for a desktop
computer* — there is no iOS app to install, and nothing from the App Store is
required. Same shape as an SSH client needing a server (Termius, Blink, Prompt).

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

- **The tour is BUILT** — "Take the tour", the primary button on the launch
  screen since the 4.2.3 fix above (it was "Try the demo" in the footer from
  build 32). Loads canned sessions and a scripted conversation, so a reviewer
  experiences the full app with zero hardware. Mention it explicitly in the
  review notes, along with the prompt library below it.

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
  accessibility size) and icon-only buttons carry VoiceOver labels (build 32);
  full pass (44pt targets, toggle labels, contrast) in build 38.
- ~~Localization~~ — 7 languages since build 34.
- ~~Widget/share-target `PrivacyInfo.xcprivacy`~~ — added to BOTH extension
  targets (build 39 tree); each bundle that touches app-group UserDefaults now
  declares CA92.1 itself, so no ITMS-91053 warnings.

## Fixed in the 1.0.0 (39) tree — resubmit nothing, just archive from here

- English local-network permission string said "Grok Remote" (stale pre-rename
  branding, and the worst possible place for it) — now "TethrX", matching the
  other 7 languages.
- Share-sheet action was titled "Send to Grok" (brand position on a SYSTEM
  surface — 5.2 bait). The extension's display name is now "TethrX"; the sheet
  inside keeps its factual wording.
- Marketing version bumped 0.9.1 → 1.0.0, build counter to 39: the public
  listing should not launch as a sub-1.0.

## Resolved (2026-07-22)

1. ~~Public URLs~~ — the repo IS public; LISTING.md now carries the working
   GitHub URLs for support + privacy policy.
2. ~~Keywords~~ — `tailscale` dropped (2.3.7); `grok,grok build` kept as
   nominative compatibility. Subtitle stays "Remote for Grok Build"
   (compatibility-format, generally accepted).
3. ~~Seller name~~ — staying on the individual account by choice; personal
   name will show as the seller.

## The only work left before submitting

**Screenshots + demo video** — iPhone 6.9" + iPad 13" sets, captured against
a demo project folder (never the home directory or real session names), plus
the 2.1 demo video of bridge start → QR pair → task → approval → git review.
Then it's just App Store Connect form-filling: privacy questionnaire ("data
not collected" everywhere), age rating (all None), EU trader declaration
(non-trader), category Developer Tools, and paste the review notes above.
