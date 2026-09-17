import AppKit
import WebKit

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!
    private var popupControllers: [BrowserWindowController] = []
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var recoveryAttempts = 0
    private var probeGeneration = 0
    private let isPopup: Bool

    init(configuration: WKWebViewConfiguration? = nil, isPopup: Bool = false) {
        self.isPopup = isPopup
        super.init()

        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            config.websiteDataStore = .default()
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        let size = isPopup ? NSSize(width: 720, height: 780) : NSSize(width: 1280, height: 900)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = isPopup ? "ChatGPT Sign In" : "ChatGPT Stable"
        window.minSize = isPopup ? NSSize(width: 560, height: 640) : NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.center()
    }

    func show(loadHome: Bool = true) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if loadHome, webView.url == nil {
            load(AppSecurityPolicy.homeURL)
        }
    }

    func load(_ url: URL) {
        guard AppSecurityPolicy.isTrustedMainFrameURL(url) else { return }
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    @objc func reload(_ sender: Any?) {
        webView.reload()
    }

    @objc func hardReload(_ sender: Any?) {
        let target = webView.url.flatMap { AppSecurityPolicy.isTrustedMainFrameURL($0) ? $0 : nil }
            ?? AppSecurityPolicy.homeURL
        webView.stopLoading()
        webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    @objc func goBack(_ sender: Any?) {
        if webView.canGoBack { webView.goBack() }
    }

    @objc func goForward(_ sender: Any?) {
        if webView.canGoForward { webView.goForward() }
    }

    @objc func goHome(_ sender: Any?) {
        load(AppSecurityPolicy.homeURL)
    }

    @objc func openCurrentPageInBrowser(_ sender: Any?) {
        guard let url = webView.url, let safeURL = AppSecurityPolicy.safeExternalURL(url) else { return }
        NSWorkspace.shared.open(safeURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recoveryAttempts = 0
        window.title = isPopup ? "ChatGPT Sign In" : "ChatGPT Stable"
        scheduleBlankPageProbe()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recoverFromRendererFailure()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    private func showLoadFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        window.title = "ChatGPT Stable - Load failed"
    }

    private func recoverFromRendererFailure() {
        guard recoveryAttempts < 2 else {
            window.title = "ChatGPT Stable - Reload required"
            return
        }
        recoveryAttempts += 1
        hardReload(nil)
    }

    private func scheduleBlankPageProbe() {
        probeGeneration += 1
        let generation = probeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, generation == self.probeGeneration else { return }
            self.probeForBlankPage()
        }
    }

    private func probeForBlankPage() {
        // This probe deliberately inspects only document readiness and element counts.
        // It never reads text, form fields, cookies, storage, or conversation contents.
        let script = "({ready:document.readyState,hasBody:!!document.body,children:document.body ? document.body.children.length : 0})"
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, error == nil, let report = value as? [String: Any] else { return }
            let hasBody = report["hasBody"] as? Bool ?? false
            let children = report["children"] as? Int ?? 0
            if !hasBody || children == 0 {
                self.recoverFromRendererFailure()
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        if !isMainFrame {
            decisionHandler(AppSecurityPolicy.isSafeSubframeURL(url, sourceURL: webView.url) ? .allow : .cancel)
            return
        }

        if AppSecurityPolicy.isTrustedMainFrameURL(url) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
            return
        }

        if let safeURL = AppSecurityPolicy.safeExternalURL(url) {
            NSWorkspace.shared.open(safeURL)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        guard AppSecurityPolicy.isTrustedMainFrameURL(url) else {
            if let safeURL = AppSecurityPolicy.safeExternalURL(url) { NSWorkspace.shared.open(safeURL) }
            return nil
        }

        let popup = BrowserWindowController(configuration: configuration, isPopup: true)
        popupControllers.append(popup)
        popup.show(loadHome: false)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        probeGeneration += 1
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        downloads.values.forEach { $0.cancel() }
        downloads.removeAll()
        if isPopup {
            popupControllers.removeAll()
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    private func track(_ download: WKDownload) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = download
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let filename = sanitizedFilename(suggestedFilename)
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        completionHandler(uniqueURL(in: directory, filename: filename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "ChatGPT Download" : String(cleaned.prefix(180))
    }

    private func uniqueURL(in directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...999 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return directory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }
}
