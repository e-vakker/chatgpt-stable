#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/dist/ChatGPT Stable.zip"
TARGET='/Applications/ChatGPT Stable.app'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-stable-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

"$ROOT/packaging/make-app.sh" >/dev/null
ditto -x -k "$ZIP" "$TMP"
APP="$TMP/ChatGPT Stable.app"
codesign --verify --deep --strict "$APP"

osascript -e 'tell application id "pro.vakker.chatgpt-stable" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$TARGET"
ditto --noextattr --noqtn "$APP" "$TARGET"
codesign --verify --deep --strict "$TARGET"
open "$TARGET"
echo "$TARGET"
