#!/bin/bash
# One-command commit + push to GitHub.
# Usage:  ./push.sh "short message"
#         ./push.sh                       # stages everything, prompts for message
set -e
cd "$(dirname "$0")" || exit 1
export PATH="$HOME/homebrew/bin:$PATH"

git add -A

MSG="$1"
if [ -z "$MSG" ]; then
  read -r -p "Commit message: " MSG
fi
[ -z "$MSG" ] && { echo "no message"; exit 1; }

# Safety: refuse to commit obvious secrets.
if git diff --cached --name-only | grep -qiE '(^|/)\.env$|\.p8$|\.p12$|\.cer$|\.mobileprovision$'; then
  echo "!! Refusing: a secret-looking file is staged. Check .gitignore." >&2
  git diff --cached --name-only | grep -iE '(^|/)\.env$|\.p8$|\.p12$|\.cer$|\.mobileprovision$' >&2
  exit 1
fi

git commit -m "$MSG"
git push origin main
echo "pushed: $MSG"
