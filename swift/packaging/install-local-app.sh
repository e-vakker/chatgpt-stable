#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/dist/ChatGPT Stable.zip"
TARGET='/Applications/ChatGPT Stable.app'
BUNDLE_ID='pro.vakker.chatgpt-stable'
PROCESS_PATTERN='^/Applications/ChatGPT Stable\.app/Contents/MacOS/ChatGPTStable$'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-stable-install.XXXXXX")"
STAGE="/Applications/.ChatGPT-Stable-stage-$$.app"
DISPLACED="/Applications/.ChatGPT-Stable-old-$$.app"
REPLACED=0
DISPLACED_READY=0

stop_running_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    ! pgrep -f "$PROCESS_PATTERN" >/dev/null && return 0
    sleep 0.3
  done
  pkill -TERM -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
  sleep 0.7
  if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    pkill -KILL -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
    sleep 0.3
  fi
  ! pgrep -f "$PROCESS_PATTERN" >/dev/null
}

rollback() {
  status=$?
  trap - EXIT INT TERM
  rm -rf "$STAGE" "$TMP"
  if [[ "$status" -ne 0 && "$REPLACED" -eq 1 ]]; then
    stop_running_app || true
    rm -rf "$TARGET"
    if [[ "$DISPLACED_READY" -eq 1 && -d "$DISPLACED" ]]; then
      mv "$DISPLACED" "$TARGET"
      open "$TARGET" >/dev/null 2>&1 || true
    fi
  fi
  [[ "$status" -eq 0 ]] && rm -rf "$DISPLACED"
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$ROOT/packaging/make-app.sh" >/dev/null
ditto -x -k "$ZIP" "$TMP"
SOURCE="$TMP/ChatGPT Stable.app"
codesign --verify --deep --strict "$SOURCE"
[[ "$(plutil -extract CFBundleIdentifier raw "$SOURCE/Contents/Info.plist")" == "$BUNDLE_ID" ]]

rm -rf "$STAGE" "$DISPLACED"
ditto --noextattr --noqtn "$SOURCE" "$STAGE"
codesign --verify --deep --strict "$STAGE"

stop_running_app || { echo 'error: previous ChatGPT Stable process would not terminate' >&2; exit 1; }

if [[ -d "$TARGET" ]]; then
  mv "$TARGET" "$DISPLACED"
  DISPLACED_READY=1
fi
mv "$STAGE" "$TARGET"
REPLACED=1
codesign --verify --deep --strict "$TARGET"

open "$TARGET"
for _ in {1..20}; do
  pgrep -f "$PROCESS_PATTERN" >/dev/null && break
  sleep 0.3
done
pgrep -f "$PROCESS_PATTERN" >/dev/null || { echo 'error: installed app did not launch' >&2; exit 1; }

REPLACED=0
DISPLACED_READY=0
rm -rf "$DISPLACED" "$TMP"
trap - EXIT INT TERM
printf '%s\n' "$TARGET"
