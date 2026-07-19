# Shipping TethrX to TestFlight

You have an Apple Developer Program membership, a team, and certificates — so this is
mostly clicking through Xcode + App Store Connect. ~20 minutes the first time.

Bundle id: **`com.tethrx.app`** · Display name: **TethrX** · internal target: `GrokRemote`.

---

## 1. Signing (Xcode)
1. `open ios/GrokRemote.xcodeproj`
2. Select the **GrokRemote** target → **Signing & Capabilities**.
3. Check **Automatically manage signing**, pick your **Team**.
   - Xcode registers the App ID `com.tethrx.app` for you. (Or pre-register it at
     developer.apple.com → Certificates, IDs & Profiles → Identifiers → +.)
4. If "com.tethrx.app" is taken on your account, change `PRODUCT_BUNDLE_IDENTIFIER`
   (Build Settings) to something you own, e.g. `com.yourname.tethrx`, and update
   `Keychain.swift`'s `service` to match.

## 2. Version + build number
- Build Settings → `MARKETING_VERSION` = `0.1` (or `1.0`), `CURRENT_PROJECT_VERSION` = `1`.
- **Bump `CURRENT_PROJECT_VERSION` every upload** (2, 3, …) — App Store Connect rejects a
  reused build number.

## 3. Create the app record (App Store Connect)
1. appstoreconnect.apple.com → **Apps** → **+** → **New App**.
2. Platform **iOS**, Name **TethrX** (must be globally unique — if taken, try "TethrX Remote"),
   primary language, **Bundle ID = com.tethrx.app**, SKU = anything (e.g. `tethrx-001`).
3. Create. (You don't need full store metadata for TestFlight — see `LISTING.md` for when you do.)

## 4. Archive (device build — not simulator)
1. In Xcode, set the run destination to **Any iOS Device (arm64)** (top bar).
2. **Product → Archive.** (Archiving requires a device target; it won't archive for a simulator.)
3. The **Organizer** opens with your archive.

## 5. Upload
1. In Organizer: **Distribute App → App Store Connect → Upload**.
2. Keep **Automatically manage signing**, accept defaults, **Upload**.
3. Wait for the "processing complete" email (a few minutes).

## 6. TestFlight
1. App Store Connect → your app → **TestFlight** tab → the build appears after processing.
2. If asked about **export compliance**, answer **No** (only exempt encryption). We already
   set `ITSAppUsesNonExemptEncryption = false`, so it usually won't ask.
3. **Internal testing** (fastest, no review): add testers who are members of your team →
   they get a TestFlight invite immediately.
   **External testing** needs a quick Beta App Review + a "what to test" note (see LISTING.md).
4. On the iPhone: install **TestFlight** from the App Store → accept the invite → install TethrX.

---

## Heads-up for testers / review
The app does nothing without a **running bridge**. Include this in your TestFlight notes:
> Install Grok Build on your computer, run `node bridge/src/server.mjs`, then in TethrX enter
> the printed address + pairing token. Same Wi-Fi, or Tailscale for cellular.

## Optional: CLI upload (no Xcode GUI)
```bash
xcodebuild -project GrokRemote.xcodeproj -scheme GrokRemote \
  -archivePath build/TethrX.xcarchive -destination 'generic/platform=iOS' archive \
  DEVELOPMENT_TEAM=YOURTEAMID
xcodebuild -exportArchive -archivePath build/TethrX.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist
xcrun altool --upload-app -f build/export/TethrX.ipa \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>   # App Store Connect API key
```
`ExportOptions.plist` needs `method = app-store-connect` and your team id. The API key path
avoids passwords; generate it in App Store Connect → Users and Access → Integrations → Keys.

## Common snags
- **"No account for team"** → add your Apple ID in Xcode → Settings → Accounts.
- **Icon rejected** → must be 1024² with **no alpha** (yours is already correct).
- **Missing privacy manifest** → `PrivacyInfo.xcprivacy` is included (declares UserDefaults, no tracking).
- **Build number already used** → bump `CURRENT_PROJECT_VERSION`.
