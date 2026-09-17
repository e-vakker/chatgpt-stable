# ChatGPT Stable

A minimal, auditable macOS shell for `https://chatgpt.com/`.

This security-focused fork intentionally keeps the native layer small. The maintained client has no cookie import/export, no native cookie reads, no prompt capture, no clipboard reads, no AppleScript, no profile cloning, no fingerprint spoofing, no GeoIP lookup, no updater framework, no telemetry endpoint, no arbitrary subprocess execution, and no third-party package dependencies.

The application uses a persistent `WKWebsiteDataStore` so ChatGPT can keep its own login state inside the app sandbox. Native code does not inspect or serialize that state.

External top-level links open in the system browser. Known ChatGPT/OpenAI authentication hosts and major OAuth providers are allowed in the WebView so login can work. The native shell provides navigation, supervised WebKit recovery, adaptive long-conversation rendering, sanitized conversation-URL checkpointing, and WebKit-managed downloads.

## Performance strategy

ChatGPT Stable cooperates with ChatGPT's native conversation virtualization instead of replacing it. A structural-only page script counts persistent turn shells and user/assistant role markers without reading message text. It recognizes the current ChatGPT shell/role attributes plus documented 2026 fallbacks. Small/native-virtualized conversations are left alone. If ChatGPT leaves more than 32 stable turns mounted near the bottom, older completed turns are hidden locally and progressively revealed when the user scrolls upward; the retained tail tightens under elevated/severe frontend pressure. During a large streaming response, older completed mounted turns can be temporarily reduced to the last four while the active response remains untouched.

Every ~30 seconds the native health probe samples DOM size and the lean layer's own structural-scan latency. Sustained severe pressure is allowed to finish streaming first, waits until the user is back near the conversation bottom and the composer is not focused, then rebuilds the `WKWebView` while reusing the same opaque WebKit website data store and sanitized conversation URL. Automatic performance refreshes have a 10-minute cooldown. `Navigation → Optimize Conversation Now` performs the same clean rebuild explicitly without counting as a crash recovery.

## Fast conversation opening

Cold conversations keep ChatGPT's own client-side navigation path. The native shell does not force a first-time chat into a new page load. Lean mode may keep a two-entry warm conversation cache: the active conversation plus one recent expensive conversation can remain as live `WKWebView` instances sharing the same opaque `WKWebsiteDataStore`. Reopening a warm conversation swaps the existing live view instead of re-fetching and re-hydrating the long thread. Terminal intentionally does not retain or proactively prewarm an idle previous chat; it uses the cache only when an actively generating source renderer must survive a switch.

Warm-cache lookup is exposed only to a separate WebKit content world through a reply-only path query. ChatGPT's ordinary JavaScript world cannot access the handler, and native code receives only a validated `/c/...`-style path. Cache misses replay the original click so ChatGPT's own SPA router handles first opens. In Lean, the most recent conversation may be prewarmed while the app is idle on Home and a settled cold navigation may prewarm the previous conversation after a delay. Prewarming is cancelled while generation is active and inactive warm views are evicted on macOS memory pressure. Initial conversation rendering also lands at the newest mounted turn instead of an arbitrary historical position. Health Diagnostics reports warm-cache hits/misses and the most recent cold/warm open mode and timing.

## Interface modes

Terminal mode is enabled by default. `Navigation → Interface` can switch between `Standard Web`, `Lean`, and `Terminal`; switching modes rebuilds only the `WKWebView` and preserves the opaque WebKit website data store. Standard Web leaves ChatGPT presentation untouched. Lean keeps the existing performance layer with conservative styling. Terminal keeps the same privacy boundary but removes most website chrome and uses a denser monospace presentation.

Terminal mode hides the ChatGPT sidebar and chat header by default, removes per-message action bars and non-send composer controls, flattens bubbles/cards/shadows, widens the transcript to a bounded 1120 px terminal column, and starts the Activity Rail collapsed. A tiny `chats` control (or Option-L) toggles the original ChatGPT sidebar without reloading. Terminal also tightens local rendering budgets: long conversations retain 12 recent visible turns normally, 8 under elevated pressure and 6 under severe pressure; completed agent activity retains 8 ordinary cards and active heavy generation retains 4. Errors and generated artifacts stay visible.

Terminal is also the low-memory mode. It does not proactively prewarm or retain an idle previous conversation; only the active WebView is retained unless another conversation is actively generating and must be protected during a switch. Critical macOS memory pressure may evict even that protected inactive view. While the Activity Rail is collapsed it keeps no activity-row DOM, skips rich-content diagnostic scans, and simple chats allocate neither the rail nor the earlier-history control. Terminal also avoids Lean's page-wide universal animation selector and backs native heartbeat probing off to roughly 30 seconds during generation.

## Lean interface

Lean mode remains available for users who want ChatGPT's original navigation/chrome with the performance layer enabled. The document-start layer removes nonfunctional motion, blur/backdrop-filter and shadow overhead, applies style containment to completed history and the composer, lazy-loads completed media, collapses completed native disclosure cards once, and hides only structurally identified upsell/promotion chrome outside conversations.

For long threads, the same rail exposes a constant-size conversation slider backed by ChatGPT's persistent turn shells, so hundreds of virtualized turns remain directly navigable without keeping their message bodies mounted. For agent-heavy turns, the rail indexes mounted Reasoning, Search, Browser, Computer, Terminal, Python, Research, Sources, Code, Table, Chart, Media, Error and Artifact structures without reading their text. Long activity streams are compacted structurally: completed sessions keep the latest 12 ordinary activity blocks mounted, high-pressure active generation keeps the latest 6, while errors and generated artifacts are protected from parking and auto-collapse. The rail itself renders only the latest 40 rows and expands older entries in batches, so the navigator cannot become a second large DOM. Clicking a parked item reveals and pins it; `Show all activity`/`Compact activity` reverses the policy.

Completed conversation action chrome is visually dormant until hover/focus. Lean mode also requires an explicit user gesture before video playback while leaving audio playback behavior unchanged. Conversation turns and the composer are marked `rr-block`, a standard session-replay exclusion marker, so replay tooling can avoid serializing the most mutation-heavy/private DOM without blocking OpenAI network domains. The optimiser schedules structural rescans at browser idle time and avoids full-document element walks; a WebKit regression test enforces a generous structural-scan budget on a synthetic 12k-node page.

## Stability supervisor

The native shell supervises WebKit without reading ChatGPT content. It uses a lightweight render heartbeat, Apple WebKit renderer-termination callbacks, `NWPathMonitor`, a navigation watchdog, and a rolling circuit breaker. Recovery escalates from reload, to cache-bypassing reload, to complete `WKWebView` replacement while preserving the opaque persistent `WKWebsiteDataStore`.

A single missed heartbeat never reloads the page. Two consecutive misses are normally required; an actively generating response gets four additional grace misses before the normal recovery threshold can be reached. Background windows are not probed, and repeated failures stop automatic recovery instead of creating a reload loop. The Health Diagnostics panel exposes only health state, network/host, content-free structural counts, performance mode/pressure and recovery counters.

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
swift test --scratch-path /tmp/chatgpt-stable-swift-tests
./packaging/make-app.sh
```

The build is deliberately not auto-installed. Run `./packaging/install-local-app.sh` only after reviewing the source and tests.
