#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatGPT Stable"
BINARY_NAME="ChatGPTStable"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-stable-build.XXXXXX")"
APP="$BUILD_ROOT/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
DIST="$ROOT/dist"
ZIP="$DIST/$APP_NAME.zip"
trap 'rm -rf "$BUILD_ROOT"' EXIT

cd "$ROOT"
./packaging/security-audit.sh
swift test
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

mkdir -p "$MACOS" "$DIST"
cp "$BIN_DIR/$BINARY_NAME" "$MACOS/$BINARY_NAME"
cp packaging/Info.plist "$CONTENTS/Info.plist"
chmod +x "$MACOS/$BINARY_NAME"

IDENTITY="${CHATGPT_STABLE_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' | head -n 1)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo 'error: an Apple Development signing identity is required for the sandboxed local build' >&2
  exit 2
fi

codesign --force --options runtime --entitlements packaging/entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security.app-sandbox'
if printf '%s' "$ENTITLEMENTS" | grep -Eq 'disable-library-validation|get-task-allow|allow-dyld-environment-variables'; then
  echo 'error: forbidden entitlement in final app' >&2
  exit 1
fi

# Binary-level supply-chain checks: this client must link only Apple system libraries.
NON_SYSTEM="$(otool -L "$MACOS/$BINARY_NAME" | awk '/^\t/ {print $1}' | grep -vE '^/System/Library/|^/usr/lib/' || true)"
if [[ -n "$NON_SYSTEM" ]]; then
  echo 'error: non-system linked library detected:' >&2
  printf '%s\n' "$NON_SYSTEM" >&2
  exit 1
fi

BINARY_URLS="$(strings "$MACOS/$BINARY_NAME" | grep -Eo 'https://[^ "<>]+' | sort -u || true)"
if [[ "$BINARY_URLS" != 'https://chatgpt.com/' ]]; then
  echo 'error: unexpected hard-coded HTTPS destination in final binary:' >&2
  printf '%s\n' "${BINARY_URLS:-<none>}" >&2
  exit 1
fi

if strings "$MACOS/$BINARY_NAME" | grep -Ei 'session-token|httpCookieStore|HTTPCookie|NSAppleScript|ipwho|ipinfo|Sparkle|Export Cookies|Paste Cookies|localStorage|sessionStorage' >/dev/null; then
  echo 'error: suspicious credential/storage indicator found in final binary' >&2
  exit 1
fi

if strings "$MACOS/$BINARY_NAME" | grep -E 'testLoadBlankDocument|testRunHeartbeat|integration test|<html><body></body></html>' >/dev/null; then
  echo 'error: DEBUG-only fault harness leaked into release binary' >&2
  exit 1
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
unzip -tq "$ZIP" >/dev/null
echo "$ZIP"
