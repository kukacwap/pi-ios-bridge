#!/bin/bash
# Build, archive, and upload PiAgentApp to TestFlight.
#
# Prerequisites (one-time, done by YOU in Apple's portals — see SUBMIT.md):
#   1. Full Xcode installed and selected:  sudo xcode-select -s /Applications/Xcode.app
#   2. Signed in to Xcode with your Apple ID (Xcode > Settings > Accounts).
#   3. Registered the App ID / bundle identifier and created the app record in
#      App Store Connect.
#   4. Created an App Store Connect API key (.p8) with "App Manager" access.
#
# Required environment variables:
#   DEVELOPMENT_TEAM     your 10-char Team ID (e.g. ABCDE12345)
#   BUNDLE_ID            e.g. com.yourname.piagent
#   ASC_KEY_ID           App Store Connect API Key ID
#   ASC_ISSUER_ID        App Store Connect Issuer ID (UUID)
#   ASC_KEY_PATH         path to the AuthKey_XXXX.p8 file
# Optional:
#   BUNDLE_ID_PREFIX     defaults to the part of BUNDLE_ID before the last dot
#   BUILD_NUMBER         defaults to a timestamp (must increase each upload)

set -euo pipefail
cd "$(dirname "$0")"

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${BUNDLE_ID:?set BUNDLE_ID (e.g. com.yourname.piagent)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to your AuthKey_*.p8}"

export BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-${BUNDLE_ID%.*}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# Require a real Xcode (Command Line Tools cannot archive iOS apps).
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: full Xcode not found. Install Xcode, then:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

echo "==> Generating Xcode project (xcodegen)"
command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate

ARCHIVE="build/PiAgentApp.xcarchive"
rm -rf build && mkdir -p build

echo "==> Archiving (build $BUILD_NUMBER)"
xcodebuild -project PiAgentApp.xcodeproj \
  -scheme PiAgentApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  archive

# Inject the team ID into a temp copy of ExportOptions.plist.
EXPORT_OPTS="build/ExportOptions.plist"
sed "s/__DEVELOPMENT_TEAM__/$DEVELOPMENT_TEAM/" ExportOptions.plist > "$EXPORT_OPTS"

echo "==> Exporting + uploading to TestFlight"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_KEY_PATH"

echo "==> Done. The build will appear in App Store Connect > TestFlight after"
echo "    Apple finishes processing (usually a few minutes). Add yourself as an"
echo "    internal tester to install it on your iPad via the TestFlight app."
