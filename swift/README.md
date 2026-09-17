# Swift client

The Swift client is the only maintained implementation on the `security/minimal-client` branch.

Its native responsibilities are intentionally narrow:

1. Create a persistent sandboxed `WKWebView` for ChatGPT.
2. Restrict top-level WebView navigation to ChatGPT/OpenAI authentication surfaces and major OAuth providers.
3. Open unrelated top-level links in the system browser.
4. Recover from a terminated or obviously blank WebKit renderer without reading page text.
5. Let WebKit handle authenticated downloads, saving only the downloaded file.

No native API reads ChatGPT cookies, local/session storage, form contents, clipboard contents, Keychain data, browser databases, or local project files.
