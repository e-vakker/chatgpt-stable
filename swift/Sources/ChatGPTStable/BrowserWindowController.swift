import AppKit
import OSLog
import WebKit

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!

    private let supervisor = HealthSupervisor()
    private let networkMonitor = NetworkMonitor()
    private let logger = Logger(subsystem: "pro.vakker.chatgpt-stable", category: "Stability")
    private let isPopup: Bool

    private var popupControllers: [BrowserWindowController] = []
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var heartbeatTimer: Timer?
    private var heartbeatTimeout: DispatchWorkItem?
    private var navigationWatchdog: DispatchWorkItem?
    private var heartbeatGeneration = 0
    private var heartbeatInFlight = false
    private var lastTrustedURL = AppSecurityPolicy.homeURL
    private var closeHandler: (() -> Void)?
    private var isClosed = false

    init(configuration: WKWebViewConfiguration? = nil, isPopup: Bool = false) {
        self.isPopup = isPopup
        super.init()

        webView = makeWebView(configuration: configuration)

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
        if isPopup {
            window.center()
        } else {
            let restored = window.setFrameUsingName("ChatGPTStable.MainWindow")
            window.setFrameAutosaveName("ChatGPTStable.MainWindow")
            if !restored { window.center() }
        }

        networkMonitor.onChange = { [weak self] online in
            self?.handleNetworkChange(online)
        }
    }

    func show(loadHome: Bool = true) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !isPopup {
            networkMonitor.start()
            startHeartbeatTimer()
        }
        if loadHome, webView.url == nil {
            load(AppSecurityPolicy.homeURL)
        }
    }

    func load(_ url: URL) {
        guard AppSecurityPolicy.isTrustedMainFrameURL(url) else { return }
        lastTrustedURL = url
        loadTrustedURL(url, cachePolicy: .useProtocolCachePolicy)
    }

    @objc func reload(_ sender: Any?) {
        guard webView.reload() != nil else {
            loadTrustedURL(lastTrustedURL, cachePolicy: .useProtocolCachePolicy)
            return
        }
        supervisor.navigationStarted()
        updateWindowTitle()
        scheduleNavigationWatchdog()
    }

    @objc func hardReload(_ sender: Any?) {
        let target = trustedCurrentURL() ?? lastTrustedURL
        loadTrustedURL(target, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func recoverNow() {
        performRecovery(supervisor.manualRecoveryRequested(), reason: "manual recovery")
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

    func presentDiagnostics() {
        let snapshot = supervisor.snapshot()
        let latency = snapshot.lastHeartbeatLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "not measured"
        let host = webView.url?.host ?? lastTrustedURL.host ?? "unknown"
        let lines = [
            "State: \(snapshot.state.rawValue)",
            "Network: \(snapshot.isOnline ? "online" : "offline")",
            "Current host: \(host)",
            "Heartbeat latency: \(latency)",
            "Recent automatic recoveries: \(snapshot.recentRecoveries)",
            "Lifetime recoveries: \(snapshot.totalRecoveries)",
            "Last failure: \(snapshot.lastFailure?.rawValue ?? "none")",
            "Last action: \(snapshot.lastAction.rawValue)",
        ]
        let alert = NSAlert()
        alert.messageText = "ChatGPT Stable Health"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Recover Now")
        if alert.runModal() == .alertSecondButtonReturn {
            recoverNow()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed else { return }
        supervisor.navigationStarted()
        updateWindowTitle()
        scheduleNavigationWatchdog()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        cancelNavigationWatchdog()
        if let current = trustedCurrentURL() {
            lastTrustedURL = current
        }
        supervisor.navigationFinished()
        updateWindowTitle()
        scheduleHeartbeat(after: 1.2)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        logger.error("WebKit content process terminated")
        if isPopup {
            hardReload(nil)
            return
        }
        performRecovery(supervisor.rendererTerminated(), reason: "renderer terminated")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        guard !isClosed else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        cancelNavigationWatchdog()
        logger.error("Navigation failed with domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")

        if isPopup {
            window.title = "ChatGPT Sign In - Load failed"
            return
        }

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            performRecovery(supervisor.networkChanged(isOnline: false), reason: "network unavailable")
        } else {
            performRecovery(supervisor.navigationFailed(), reason: "navigation failed")
        }
    }

    private func makeWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            config.websiteDataStore = .default()
        }
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    private func loadTrustedURL(_ url: URL, cachePolicy: URLRequest.CachePolicy) {
        guard AppSecurityPolicy.isTrustedMainFrameURL(url), !isClosed else { return }
        lastTrustedURL = url
        cancelHeartbeatTimeout()
        cancelNavigationWatchdog()
        supervisor.navigationStarted()
        updateWindowTitle()
        scheduleNavigationWatchdog()
        webView.stopLoading()
        webView.load(URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 30))
    }

    private func trustedCurrentURL() -> URL? {
        guard let url = webView.url, AppSecurityPolicy.isTrustedMainFrameURL(url) else { return nil }
        return url
    }

    private func performRecovery(_ action: RecoveryAction, reason: String) {
        guard !isClosed else { return }
        logger.notice("Recovery action=\(action.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        updateWindowTitle()

        switch action {
        case .none, .pauseForNetwork, .requireManual:
            return
        case .softReload:
            cancelHeartbeatTimeout()
            guard webView.reload() != nil else {
                loadTrustedURL(lastTrustedURL, cachePolicy: .useProtocolCachePolicy)
                return
            }
            scheduleNavigationWatchdog()
        case .hardReload:
            loadTrustedURL(trustedCurrentURL() ?? lastTrustedURL, cachePolicy: .reloadIgnoringLocalCacheData)
        case .rebuildWebView:
            rebuildWebView()
        }
    }

    private func rebuildWebView() {
        guard !isClosed else { return }
        let target = trustedCurrentURL() ?? lastTrustedURL
        let oldView = webView!
        let dataStore = oldView.configuration.websiteDataStore

        oldView.stopLoading()
        oldView.navigationDelegate = nil
        oldView.uiDelegate = nil

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let replacement = makeWebView(configuration: configuration)
        replacement.frame = oldView.frame
        replacement.autoresizingMask = [.width, .height]
        webView = replacement
        window.contentView = replacement

        loadTrustedURL(target, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    private func startHeartbeatTimer() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runHeartbeatIfAppropriate()
            }
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        cancelHeartbeatTimeout()
    }

    private func scheduleHeartbeat(after delay: TimeInterval) {
        guard !isPopup else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runHeartbeatIfAppropriate()
        }
    }

    private func runHeartbeatIfAppropriate(force: Bool = false) {
        guard !isPopup, !isClosed, !webView.isLoading, !heartbeatInFlight else { return }
        if !force, (!window.isVisible || !NSApp.isActive) { return }

        let snapshot = supervisor.snapshot()
        guard snapshot.isOnline,
              snapshot.state != .waitingForNetwork,
              snapshot.state != .recovering,
              snapshot.state != .failed else { return }

        heartbeatGeneration += 1
        let generation = heartbeatGeneration
        heartbeatInFlight = true
        let started = Date()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.heartbeatInFlight, self.heartbeatGeneration == generation else { return }
            self.heartbeatInFlight = false
            let action = self.supervisor.heartbeatTimedOut()
            self.performRecovery(action, reason: "heartbeat timeout")
        }
        heartbeatTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)

        let script = "(() => { const b=document.body; return {ready:document.readyState,hasBody:!!b,children:b ? b.children.length : 0,challenge:location.pathname.startsWith('/cdn-cgi/')}; })()"
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, self.heartbeatInFlight, self.heartbeatGeneration == generation else { return }
            self.heartbeatInFlight = false
            self.cancelHeartbeatTimeout()

            guard error == nil, let report = value as? [String: Any] else {
                let action = self.supervisor.heartbeatTimedOut()
                self.performRecovery(action, reason: "heartbeat evaluation failed")
                return
            }

            let hasBody = report["hasBody"] as? Bool ?? false
            let children = (report["children"] as? NSNumber)?.intValue ?? 0
            let challenge = report["challenge"] as? Bool ?? false
            let renderable = challenge || (hasBody && children > 0)
            let latency = Date().timeIntervalSince(started)
            let action = self.supervisor.heartbeatSucceeded(latency: latency, renderable: renderable)
            self.performRecovery(action, reason: renderable ? "heartbeat healthy" : "blank render")
            self.updateWindowTitle()
        }
    }

    private func cancelHeartbeatTimeout() {
        heartbeatTimeout?.cancel()
        heartbeatTimeout = nil
    }

    private func scheduleNavigationWatchdog(after delay: TimeInterval = 35) {
        guard !isPopup else { return }
        cancelNavigationWatchdog()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed, self.webView.isLoading else { return }
            guard self.window.isVisible, NSApp.isActive else {
                self.scheduleNavigationWatchdog(after: 15)
                return
            }
            self.performRecovery(self.supervisor.navigationStalled(), reason: "navigation watchdog")
        }
        navigationWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelNavigationWatchdog() {
        navigationWatchdog?.cancel()
        navigationWatchdog = nil
    }

    private func handleNetworkChange(_ online: Bool) {
        guard !isPopup, !isClosed else { return }
        let action = supervisor.networkChanged(isOnline: online)
        logger.info("Network state changed online=\(online)")
        updateWindowTitle()
        if action == .hardReload || action == .rebuildWebView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performRecovery(action, reason: "network restored")
            }
        }
    }

    private func updateWindowTitle() {
        guard !isPopup else { return }
        let suffix: String
        switch supervisor.snapshot().state {
        case .starting: suffix = "Starting"
        case .loading: suffix = "Loading"
        case .healthy: suffix = ""
        case .degraded: suffix = "Checking connection"
        case .waitingForNetwork: suffix = "Offline"
        case .recovering: suffix = "Recovering"
        case .failed: suffix = "Manual recovery required"
        }
        window.title = suffix.isEmpty ? "ChatGPT Stable" : "ChatGPT Stable - \(suffix)"
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleHeartbeat(after: 0.6)
    }

#if DEBUG
    func testLoadBlankDocument() {
        webView.loadHTMLString("<html><body></body></html>", baseURL: AppSecurityPolicy.homeURL)
    }

    func testRunHeartbeat() {
        runHeartbeatIfAppropriate(force: true)
    }

    func testHealthSnapshot() -> BrowserHealthSnapshot {
        supervisor.snapshot()
    }

    func testRebuildWebView() {
        performRecovery(.rebuildWebView, reason: "integration test")
    }
#endif

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
            if let safeURL = AppSecurityPolicy.safeExternalURL(url) {
                NSWorkspace.shared.open(safeURL)
            }
            return nil
        }

        let popup = BrowserWindowController(configuration: configuration, isPopup: true)
        popup.closeHandler = { [weak self, weak popup] in
            guard let popup else { return }
            self?.popupControllers.removeAll { $0 === popup }
        }
        popupControllers.append(popup)
        popup.show(loadHome: false)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(AppSecurityPolicy.isMediaCaptureHost(origin.host.lowercased()) ? .prompt : .deny)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        heartbeatGeneration += 1
        stopHeartbeatTimer()
        cancelNavigationWatchdog()
        networkMonitor.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        downloads.values.forEach { $0.cancel() }
        downloads.removeAll()
        closeHandler?()
        closeHandler = nil
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
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        completionHandler(uniqueURL(in: directory, filename: filename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        logger.error("Download failed: \(error.localizedDescription, privacy: .private)")
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
