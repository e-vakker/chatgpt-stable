# ChatGPT Stable

A minimal, auditable macOS shell for `https://chatgpt.com/`.

This security-focused fork intentionally keeps the native layer small. The maintained client has no cookie import/export, no native cookie reads, no prompt capture, no clipboard reads, no AppleScript, no profile cloning, no fingerprint spoofing, no GeoIP lookup, no updater framework, no telemetry endpoint, no arbitrary subprocess execution, and no third-party package dependencies.

The application uses a persistent `WKWebsiteDataStore` so ChatGPT can keep its own login state inside the app sandbox. Native code does not inspect or serialize that state.

External top-level links open in the system browser. Known ChatGPT/OpenAI authentication hosts and major OAuth providers are allowed in the WebView so login can work. The native shell provides only navigation, WebKit crash/blank-page recovery, and WebKit-managed downloads.

## Stability supervisor

The native shell supervises WebKit without reading ChatGPT content. It uses a lightweight render heartbeat, Apple WebKit renderer-termination callbacks, `NWPathMonitor`, a navigation watchdog, and a rolling circuit breaker. Recovery escalates from reload, to cache-bypassing reload, to complete `WKWebView` replacement while preserving the opaque persistent `WKWebsiteDataStore`.

A single missed heartbeat never reloads the page. Two consecutive misses are required, background windows are not probed, and repeated failures stop automatic recovery instead of creating a reload loop. The Health Diagnostics panel exposes only state, network availability, current host, heartbeat latency and recovery counters.

## Security properties

- App Sandbox enabled.
- Hardened Runtime enabled.
- No `disable-library-validation` entitlement.
- No `get-task-allow` entitlement.
- Network client entitlement only for WebKit.
- Downloads folder write access only for WebKit downloads.
- No third-party Swift packages.
- `packaging/security-audit.sh` rejects high-risk APIs and unexpected hard-coded network destinations.

## Build

```bash
cd swift
./packaging/security-audit.sh
swift test
./packaging/make-app.sh
```

The build is deliberately not auto-installed. Run `./packaging/install-local-app.sh` only after reviewing the source and tests.
