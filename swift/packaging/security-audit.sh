#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

forbidden='httpCookieStore|HTTPCookie|NSAppleScript|NSPasteboard\.general\.string|URLSession|Process\(|WKScriptMessageHandler|WKUserScript|document\.cookie|localStorage|sessionStorage|navigator\.clipboard|XMLHttpRequest|fetch\(|ipwho\.is|ipinfo\.io|Sparkle|dlopen|SecItem|kSec[A-Z]|Data\(contentsOf|homeDirectoryForCurrentUser|UserDefaults|disable-library-validation|get-task-allow|allow-dyld-environment-variables'
if grep -RInE "$forbidden" Sources Package.swift packaging/Info.plist packaging/entitlements.plist; then
  echo 'error: forbidden high-risk API or feature found in maintained client code' >&2
  exit 1
fi


# JavaScript evaluation is permitted only for the tiny blank-render probe in BrowserWindowController.
js_count="$(grep -Rho 'evaluateJavaScript' Sources | wc -l | tr -d ' ')"
if [[ "$js_count" != "1" ]]; then
  echo "error: expected exactly one evaluateJavaScript call, found $js_count" >&2
  exit 1
fi
if grep -RInE 'textContent|innerText|querySelector|value[[:space:]]*[:=]|document\.forms' Sources/ChatGPTStable/BrowserWindowController.swift; then
  echo 'error: blank-page probe must not inspect page text or form contents' >&2
  exit 1
fi

# The only permitted hard-coded HTTPS destination in maintained source is ChatGPT itself.
urls="$(grep -RhoE 'https://[^"[:space:]]+' Sources 2>/dev/null | sort -u || true)"
if [[ -n "$urls" && "$urls" != 'https://chatgpt.com/' ]]; then
  echo 'error: unexpected hard-coded HTTPS destination:' >&2
  printf '%s\n' "$urls" >&2
  exit 1
fi

# Keep the maintained implementation and UI English-only for easy review.
if LC_ALL=C grep -RInP '[\x{3400}-\x{9FFF}]' Sources Tests packaging 2>/dev/null; then
  echo 'error: CJK text found in maintained client code' >&2
  exit 1
fi

if grep -q '\.package(' Package.swift; then
  echo 'error: third-party Swift package dependency found' >&2
  exit 1
fi

echo 'Security source audit passed.'
