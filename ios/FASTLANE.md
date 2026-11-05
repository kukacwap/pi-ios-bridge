# TestFlight with Fastlane

Alternative to `testflight.sh`. Fastlane handles signing, build, and upload, and
makes tester management easy. Auth uses an App Store Connect API key (no 2FA prompts).

## Prerequisites

Same Apple one-time setup as [`SUBMIT.md`](SUBMIT.md) sections 0–1:
full Xcode, `xcodegen`, Team ID, registered bundle ID, app record, and an
App Store Connect API key (`.p8` + Key ID + Issuer ID).

Fastlane needs **Ruby 2.7+** (this Mac's system Ruby is 2.6). Install a newer Ruby:

```bash
brew install rbenv
rbenv install 3.3.5 && rbenv local 3.3.5    # run inside ios/PiAgentApp
# or: brew install ruby  (then add it to PATH)
```

## Install fastlane (bundler-managed)

```bash
cd ~/pi-ios-bridge/ios/PiAgentApp
gem install bundler
bundle install            # installs fastlane + xcodeproj from Gemfile
```

## Configure

```bash
export DEVELOPMENT_TEAM=ABCDE12345
export BUNDLE_ID=com.yourname.piagent
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXX.p8

# Optional: auto-invite yourself as a tester after upload
export TESTER_EMAIL=you@example.com
export TESTER_FIRST=Your
export TESTER_LAST=Name
export TESTFLIGHT_GROUP=Internal     # defaults to "Internal"
```

## Ship

```bash
cd ~/pi-ios-bridge/ios/PiAgentApp
bundle exec fastlane beta
```

This regenerates the Xcode project, builds a signed Release IPA, uploads to
TestFlight, distributes to the TestFlight group, and — if `TESTER_EMAIL` is set —
adds you as a tester automatically.

Other lanes:

```bash
bundle exec fastlane generate      # just (re)generate the .xcodeproj
bundle exec fastlane invite        # add TESTER_EMAIL to the group (no build)
bundle exec fastlane upload_only   # upload an existing build/PiAgentApp.ipa
```

### About the tester group

- Create the group once in App Store Connect → your app → TestFlight →
  **Internal Testing** → **+** → name it `Internal` (match `TESTFLIGHT_GROUP`).
- **Internal** testers must be Users in App Store Connect (your own Apple ID
  already is, as the account holder) and get builds with **no App Review**.
- The `invite` lane adds the email to that group; accept the invite email on the
  iPad, then install via the TestFlight app.
- To use **external** testers instead (up to 10,000, by email, but each build
  needs a one-time Beta App Review), set `distribute_external: true` and
  `notify_external_testers: true` in the `Fastfile` and use an external group name.

## Install on the iPad

App Store Connect → your app → TestFlight → **Internal Testing** → add yourself.
Then open the TestFlight app on the iPad (same Apple ID) and install **Pi Agent**.
Internal testers need no App Review.

## Which to use?

| | `testflight.sh` | Fastlane `beta` |
|---|---|---|
| Deps | Xcode + xcodegen | Xcode + xcodegen + Ruby 3 + fastlane |
| Auth | xcodebuild `-authenticationKey*` | ASC API key object |
| Tester mgmt | manual in web UI | `pilot`/lanes can automate |
| Best for | minimal, one-off | repeatable releases |

Both produce the same TestFlight build. Fastlane is nicer if you'll iterate.
