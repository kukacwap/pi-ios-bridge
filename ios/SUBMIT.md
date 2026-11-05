# Ship PiAgentApp to TestFlight

The `testflight.sh` script automates archive + upload. But a few things can only
be done by you (they require your Apple account). Do the one-time setup, then run
one command for every build.

## 0. Install tooling (this Mac currently lacks it)

This machine has only Command Line Tools. You need **full Xcode**:

```bash
# From the App Store (search "Xcode"), or:
xcode-select --install          # NOT enough by itself — that's just CLT
# After installing Xcode.app:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version             # should now print Xcode 16.x

brew install xcodegen           # project generator
```

Open Xcode once, accept the license, and sign in:
**Xcode ▸ Settings ▸ Accounts ▸ +** → your Apple Developer ID.

## 1. One-time Apple setup (web UI)

### a. Find your Team ID
[developer.apple.com/account](https://developer.apple.com/account) → Membership →
copy the **Team ID** (10 chars, e.g. `ABCDE12345`).

### b. Register the App ID (bundle identifier)
Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App.
- Description: `Pi Agent`
- Bundle ID: **Explicit**, e.g. `com.yourname.piagent`
  (must be globally unique; use your own reverse-domain).
- Capabilities: none needed. Register.

### c. Create the app record in App Store Connect
[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps → **+** → New App.
- Platform: iOS
- Name: `Pi Agent` (must be unique across the store; tweak if taken)
- Primary language, Bundle ID (pick the one from step b), SKU: any string.
Create. (You do NOT need to fill store metadata for TestFlight.)

### d. Create an App Store Connect API key
App Store Connect → Users and Access → **Integrations / Keys** → App Store Connect API
→ **+** → Access: **App Manager** → Generate.
- Download the `AuthKey_XXXXXX.p8` **once** (can't re-download). Save it, e.g.
  `~/.appstoreconnect/private_keys/AuthKey_XXXXXX.p8`.
- Note the **Key ID** and the **Issuer ID** (shown on that page).

## 2. Run the upload

```bash
cd ~/pi-ios-bridge/ios/PiAgentApp

export DEVELOPMENT_TEAM=ABCDE12345
export BUNDLE_ID=com.yourname.piagent
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXX.p8

./testflight.sh
```

The script generates the Xcode project, archives a Release build with automatic
signing, exports it, and uploads straight to App Store Connect.

Re-running later? Bump the build with `export BUILD_NUMBER=$(date +%Y%m%d%H%M)`
(the script already defaults to a timestamp, so each run auto-increments).

## 3. Install on your iPad

1. App Store Connect → your app → **TestFlight** tab.
2. Wait for the build to finish **Processing** (a few minutes).
3. You may get a one-time "Export Compliance" question — this app uses only
   standard HTTPS/WebSocket (no custom crypto), so answer that it's exempt.
4. Add yourself under **Internal Testing** (uses your Apple ID; no review needed).
5. On the iPad: install **TestFlight** from the App Store, sign in with the same
   Apple ID, and install **Pi Agent**.

## Notes

- **Internal testers** (up to 100, must be on your team) get builds immediately
  with no App Review. That's the fastest path for your own iPad.
- Make sure Tailscale is running on the iPad; configure the app with host
  `100.126.26.86`, port `8787`, and your `BRIDGE_TOKEN`.
- The bridge must be running on the Mac (`./service.sh status`).
