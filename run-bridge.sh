#!/bin/bash
# Wrapper that loads .env and runs the bridge. Used by launchd and by hand.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  echo "run-bridge.sh: .env not found (copy .env.example -> .env)" >&2
  exit 1
fi

# Ensure a node is on PATH for launchd's minimal environment.
export PATH="$HOME/.local/share/pi-node/current/bin:$HOME/.pi/agent/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

exec node server.js
