#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

forbidden='httpCookieStore|HTTPCookie|NSAppleScript|NSPasteboard\.general\.string|URLSession|Process\(|document\.cookie|localStorage|sessionStorage|navigator\.clipboard|XMLHttpRequest|fetch\(|ipwho\.is|ipinfo\.io|Sparkle|dlopen|SecItem|kSec[A-Z]|Data\(contentsOf|homeDirectoryForCurrentUser|disable-library-validation|get-task-allow|allow-dyld-environment-variables'
if grep -RInE "$forbidden" Sources Package.swift packaging/Info.plist packaging/entitlements.plist; then
  echo 'error: forbidden high-risk API or feature found in maintained client code' >&2
  exit 1
fi

# Exactly one isolated, reply-only native bridge is allowed for warm-conversation routing.
handler_files="$(grep -Rl 'WKScriptMessageHandler' Sources 2>/dev/null | sort || true)"
if [[ "$handler_files" != 'Sources/ChatGPTStable/WarmCacheBridge.swift' ]]; then
  echo 'error: native script-message handlers are permitted only in WarmCacheBridge.swift' >&2
  printf '%s\n' "${handler_files:-<none>}" >&2
  exit 1
fi
if grep -nE 'document\.cookie|localStorage|sessionStorage|URLSession|NSPasteboard|SecItem|httpCookieStore|HTTPCookie|FileManager|Data\(contentsOf|fetch\(|XMLHttpRequest' Sources/ChatGPTStable/WarmCacheBridge.swift; then
  echo 'error: warm cache bridge crossed the path-only data boundary' >&2
  exit 1
fi
if ! grep -q 'contentWorld: PerformanceOptimizer.routeContentWorld' Sources/ChatGPTStable/BrowserWindowController.swift; then
  echo 'error: warm cache bridge must be registered in its isolated content world' >&2
  exit 1
fi

# Static page-side scripts may inspect structural attributes only. They must not read message/form
# text, credentials, browser storage, or open a network channel.
user_script_files="$(grep -Rl 'WKUserScript' Sources 2>/dev/null || true)"
if [[ "$user_script_files" != 'Sources/ChatGPTStable/PerformanceOptimizer.swift' ]]; then
  echo 'error: WKUserScript is permitted only in PerformanceOptimizer.swift' >&2
  printf '%s\n' "${user_script_files:-<none>}" >&2
  exit 1
fi
if grep -nE 'document\.cookie|localStorage|sessionStorage|fetch\(|XMLHttpRequest|navigator\.clipboard|textContent|innerText|innerHTML|outerHTML|insertAdjacentHTML|\.value\b|WKScriptMessageHandler|URLSession|httpCookieStore|HTTPCookie|NSAppleScript|UserDefaults' Sources/ChatGPTStable/PerformanceOptimizer.swift; then
  echo 'error: performance optimizer crossed the structural-only data boundary' >&2
  exit 1
fi
if grep -nE 'document\.cookie|localStorage|sessionStorage|fetch\(|XMLHttpRequest|navigator\.clipboard|textContent|innerText|innerHTML|outerHTML|insertAdjacentHTML|\.value\b|WKScriptMessageHandler|URLSession|httpCookieStore|HTTPCookie|NSAppleScript|UserDefaults' Sources/ChatGPTStable/TerminalInterface.swift; then
  echo 'error: terminal interface crossed the structural-only data boundary' >&2
  exit 1
fi
if ! grep -q 'WKUserScript(source: TerminalInterface.source, injectionTime: \.atDocumentStart' Sources/ChatGPTStable/PerformanceOptimizer.swift; then
  echo 'error: terminal interface must be installed at document start' >&2
  exit 1
fi
if ! grep -q 'injectionTime: \.atDocumentStart' Sources/ChatGPTStable/PerformanceOptimizer.swift; then
  echo 'error: lean UI must be installed at document start' >&2
  exit 1
fi

# Local persistence is limited to one sanitized ChatGPT URL checkpoint.
user_defaults_files="$(grep -Rl 'UserDefaults' Sources 2>/dev/null || true)"
if [[ "$user_defaults_files" != 'Sources/ChatGPTStable/SessionCheckpoint.swift' ]]; then
  echo 'error: UserDefaults is permitted only for SessionCheckpoint.swift' >&2
  printf '%s\n' "${user_defaults_files:-<none>}" >&2
  exit 1
fi
if grep -nEi 'cookie|token|prompt|message|content|body|credential|password' Sources/ChatGPTStable/SessionCheckpoint.swift; then
  echo 'error: session checkpoint may persist only a sanitized page URL' >&2
  exit 1
fi

# Native JavaScript evaluation is permitted only for the structural health/performance probe.
js_count="$(grep -Rho 'evaluateJavaScript' Sources | wc -l | tr -d ' ')"
if [[ "$js_count" != "1" ]]; then
  echo "error: expected exactly one evaluateJavaScript call, found $js_count" >&2
  exit 1
fi
if grep -RInE 'textContent|innerText|querySelector|value[[:space:]]*[:=]|document\.forms' Sources/ChatGPTStable/BrowserWindowController.swift; then
  echo 'error: native structural probe must not inspect page text or form contents' >&2
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
