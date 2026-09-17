# Security model

`security/minimal-client` treats the native shell as untrusted infrastructure around ChatGPT Web and keeps its capabilities deliberately narrow.

## Native code may

- create a persistent sandboxed `WKWebView` for `https://chatgpt.com/`;
- allow known OpenAI authentication surfaces and major OAuth providers as top-level WebView destinations;
- open unrelated HTTPS links in the system browser;
- reload the current trusted page after a WebKit renderer failure or an obviously blank document;
- persist only a sanitized ChatGPT page URL with query and fragment removed;
- run one static, local structural-performance script that may count DOM/turn/activity markers, apply local CSS, and hide/reveal completed turn or activity shells without reading their text;
- add local `rr-block` replay-exclusion markers to conversation turns, the composer and the local Activity Rail;
- receive a completed WebKit download and choose a unique filename in Downloads.

## Native code must not

- read, enumerate, clone, import, export, log, or serialize browser cookies;
- read `localStorage`, `sessionStorage`, form text, conversation text, or ChatGPT prompt text;
- read the clipboard, Keychain, browser databases, SSH material, project files, or arbitrary local files;
- execute AppleScript or arbitrary subprocesses;
- use `URLSession`, `fetch`, XHR, or another native/JS telemetry channel;
- spoof browser fingerprints or query GeoIP services;
- load a third-party update framework;
- link non-system libraries;
- carry `disable-library-validation`, `get-task-allow`, or DYLD-environment entitlements.

## Stability boundary

The supervisor may inspect document readiness, body/DOM counts, focus type, element tags and structural attributes such as `data-turn-id`, `data-turn-id-container`, `data-testid`, `data-message-author-role`, `data-role`, `data-message-author`, `aria-busy`, and `aria-label` used to identify turn shells, generation controls and visible activity categories. The page script may modify local classes/styles/attributes and disclosure open state, but it must not inspect text, form values, prompts, messages, cookies or Web Storage. Native heartbeat checks run only while the app is active and visible, and back off while generation is active.

The strongest recovery creates a new `WKWebView` and reuses the existing `WKWebsiteDataStore` object without enumerating its contents. DEBUG-only fault-injection hooks are compiled out of release builds, and the release packager rejects the build if their strings appear in the final binary.

## Build gates

`swift/packaging/security-audit.sh` rejects high-risk APIs, unexpected hard-coded HTTPS destinations, CJK UI/source text, third-party Swift dependencies, additional native JavaScript evaluation sites, and any performance-script attempt to read content/forms/storage or open a network channel.

`swift/packaging/make-app.sh` reruns the source audit and tests, signs with App Sandbox + Hardened Runtime, verifies the signature, rejects forbidden entitlements, rejects non-system linked libraries, checks the final binary's URL strings, and checks for credential/storage indicators.

The build does not install or launch the application automatically.
