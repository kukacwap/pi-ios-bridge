#!/bin/bash
# Build + upload PiAgentApp to TestFlight. Run this in Terminal.app (GUI session)
# so codesign can access the signing key — click "Always Allow" if prompted.
set -euo pipefail
cd "$(dirname "$0")"

# Use the project-pinned Ruby (rbenv) if available.
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

if [[ ! -f .env.ios ]]; then
  echo "Missing .env.ios (Team ID / bundle ID / API key config)." >&2
  exit 1
fi
set -a; source .env.ios; set +a

exec bundle exec fastlane beta
