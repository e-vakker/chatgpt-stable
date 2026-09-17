import AppKit
import Dispatch
import OSLog
import WebKit

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!

    private let supervisor = HealthSupervisor()
    private let pressureController = PerformancePressureController()
    private let networkMonitor = NetworkMonitor()
    private let logger = Logger(subsystem: "pro.vakker.chatgpt-stable", category: "Stability")
    private let warmConversationCache = WarmConversationCache(maxEntries: 2)
    private let isPopup: Bool
    private var interfaceMode: InterfaceMode = .terminal

    private var popupControllers: [BrowserWindowController] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var warmPreloadWorkItem: DispatchWorkItem?
    private var activeConversationKey: String?
    private var pendingColdConversationKey: String?
    private var pendingColdOpenStartedAt: Date?
    private var lastConversationOpenMode = "none"
    private var lastConversationOpenDuration: TimeInterval?
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var heartbeatTimer: Timer?
    private var heartbeatTimeout: DispatchWorkItem?
    private var navigationWatchdog: DispatchWorkItem?
    private var heartbeatGeneration = 0
    private var heartbeatInFlight = false
    private var lastHeartbeatStartedAt: Date?
    private var lastDOMNodeCount = 0
    private var lastTurnShellCount = 0
    private var lastMountedRoleCount = 0
    private var lastRawRoleCount = 0
    private var lastHiddenTurnCount = 0
    private var lastPerformanceMode = "native"
    private var lastIsGenerating = false
    private var lastGenerationReason = "none"
    private var lastComposerFocused = false
    private var lastNearBottom = true
    private var lastActivityTotal = 0
    private var lastReasoningCount = 0
    private var lastToolCount = 0
    private var lastDetailCount = 0
    private var lastErrorCount = 0
    private var lastArtifactCount = 0
    private var lastCodeCount = 0
    private var lastTableCount = 0
    private var lastMediaCount = 0
    private var lastOptimizerScanMs: Double = 0
    private var lastHiddenActivityCount = 0
    private var lastActivityMode = "all"
    private var lastTrustedURL = AppSecurityPolicy.homeURL
    private var closeHandler: (() -> Void)?
    private var isClosed = false

    init(configuration: WKWebViewConfiguration? = nil, isPopup: Bool = false) {
        self.isPopup = isPopup
        super.init()
        if !isPopup {
            lastTrustedURL = SessionCheckpoint.load() ?? AppSecurityPolicy.homeURL
        }

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
            startMemoryPressureMonitor()
        }
        if loadHome, webView.url == nil {
            load(lastTrustedURL)
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

    func optimizeNow() {
        pressureController.manualRefreshPerformed()
        performPerformanceRefresh(reason: "manual conversation optimization")
    }

    func setInterfaceMode(_ mode: InterfaceMode) {
        guard !isPopup, interfaceMode != mode else { return }
        interfaceMode = mode
        rebuildWebView()
    }

    func currentInterfaceMode() -> InterfaceMode { interfaceMode }

    func setLeanInterfaceEnabled(_ enabled: Bool) {
        setInterfaceMode(enabled ? .lean : .standard)
    }

    func isLeanInterfaceEnabled() -> Bool { interfaceMode.usesPerformanceLayer }

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
        let pressure = pressureController.snapshot()
        let cache = warmConversationCache.stats()
        let latency = snapshot.lastHeartbeatLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "not measured"
        let openTime = lastConversationOpenDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? "pending"
        let host = webView.url?.host ?? lastTrustedURL.host ?? "unknown"
        let lines = [
            "State: \(snapshot.state.rawValue)",
            "Network: \(snapshot.isOnline ? "online" : "offline")",
            "Current host: \(host)",
            "Interface: \(interfaceMode.displayName)",
            "Warm chat cache: \(cache.count)/2 (hits \(cache.hits), misses \(cache.misses))",
            "Last chat open: \(lastConversationOpenMode) · \(openTime)",
            "Heartbeat latency: \(latency)",
            "DOM nodes: \(lastDOMNodeCount)",
            "Turn shells: \(lastTurnShellCount)",
            "Mounted message roles: \(lastMountedRoleCount) / raw \(lastRawRoleCount)",
            "Locally hidden turns: \(lastHiddenTurnCount)",
            "Performance mode: \(lastPerformanceMode)",
            "Performance pressure: \(pressure.level.rawValue)",
            "Performance refresh pending: \(pressure.pendingRefresh ? "yes" : "no")",
            "Automatic performance refreshes: \(pressure.automaticRefreshes)",
            "Generating: \(lastIsGenerating ? "yes" : "no") (\(lastGenerationReason))",
            "Composer focused: \(lastComposerFocused ? "yes" : "no")",
            "Near conversation bottom: \(lastNearBottom ? "yes" : "no")",
            "Activity: \(lastActivityTotal) (tool \(lastToolCount), reasoning \(lastReasoningCount), errors \(lastErrorCount), artifacts \(lastArtifactCount))",
            "Activity mode: \(lastActivityMode), parked \(lastHiddenActivityCount)",
            "Lean scan: \(String(format: "%.1f ms", lastOptimizerScanMs))",
            "Rich content: code \(lastCodeCount), tables \(lastTableCount), media \(lastMediaCount)",
            "Generation heartbeat grace misses: \(snapshot.generationHeartbeatTimeouts)",
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
            if !isPopup {
                SessionCheckpoint.save(current)
                if let key = AppSecurityPolicy.conversationKey(for: current) {
                    warmConversationCache.store(webView, for: key, protected: lastIsGenerating)
                    activeConversationKey = key
                    disposeEvictedViews(warmConversationCache.evictIfNeeded(excluding: key))
                } else {
                    warmConversationCache.remove(view: webView)
                    activeConversationKey = nil
                }
            }
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
        if !isPopup, interfaceMode.usesPerformanceLayer {
            config.mediaTypesRequiringUserActionForPlayback = [.video]
            let bridge = WarmCacheBridge(owner: self)
            config.userContentController.addScriptMessageHandler(
                bridge,
                contentWorld: PerformanceOptimizer.routeContentWorld,
                name: PerformanceOptimizer.routeHandlerName
            )
            PerformanceOptimizer.install(
                into: config.userContentController,
                terminalMode: interfaceMode.isTerminal
            )
        }

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

    private func cacheActiveConversationIfNeeded() {
        warmConversationCache.remove(view: webView)
        let candidateURL = trustedCurrentURL() ?? lastTrustedURL
        guard let key = AppSecurityPolicy.conversationKey(for: candidateURL) else {
            activeConversationKey = nil
            return
        }
        warmConversationCache.store(webView, for: key, protected: lastIsGenerating)
        activeConversationKey = key
        disposeEvictedViews(warmConversationCache.evictIfNeeded(excluding: key))
    }

    func warmCacheDecision(for path: String) -> String {
        guard let targetURL = AppSecurityPolicy.conversationURL(forPath: path),
              let targetKey = AppSecurityPolicy.conversationKey(for: targetURL) else { return "cold-spa" }
        if warmConversationCache.containsKey(targetKey) { return "warm" }

        lastConversationOpenMode = "cold-spa"
        lastConversationOpenDuration = nil
        pendingColdConversationKey = targetKey
        pendingColdOpenStartedAt = Date()

        let sourceCandidate = trustedCurrentURL() ?? lastTrustedURL
        if let source = AppSecurityPolicy.checkpointURL(sourceCandidate),
           let sourceKey = AppSecurityPolicy.conversationKey(for: source),
           sourceKey != targetKey {
            if lastIsGenerating {
                lastConversationOpenMode = "preserve-current"
                cacheActiveConversationIfNeeded()
                return "preserve-current"
            }
            schedulePreviousConversationPrewarm(source, key: sourceKey)
        }
        return "cold-spa"
    }

    func prewarmConversation(for path: String) -> String {
        guard !isPopup, window.isVisible, !lastIsGenerating,
              let targetURL = AppSecurityPolicy.conversationURL(forPath: path),
              let key = AppSecurityPolicy.conversationKey(for: targetURL),
              key != activeConversationKey else { return "ignored" }
        if warmConversationCache.containsKey(key) { return "warm" }
        guard warmConversationCache.stats().count < 2 else { return "full" }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        let preload = makeWebView(configuration: configuration)
        preload.navigationDelegate = nil
        preload.uiDelegate = nil
        warmConversationCache.store(preload, for: key, protected: false)
        disposeEvictedViews(warmConversationCache.evictIfNeeded(excluding: activeConversationKey))
        preload.load(URLRequest(url: targetURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        logger.debug("Proactively prewarming recent conversation")
        return "scheduled"
    }

    private func schedulePreviousConversationPrewarm(_ url: URL, key: String, attempt: Int = 0) {
        warmPreloadWorkItem?.cancel()
        let sourceView = webView!
        let dataStore = sourceView.configuration.websiteDataStore
        let item = DispatchWorkItem { [weak self, weak sourceView] in
            guard let self, let sourceView, !self.isClosed, sourceView === self.webView else { return }
            let currentKey = self.webView.url.flatMap(AppSecurityPolicy.conversationKey(for:))
            if currentKey == key {
                if attempt < 2 { self.schedulePreviousConversationPrewarm(url, key: key, attempt: attempt + 1) }
                return
            }
            if self.lastIsGenerating {
                if attempt < 2 { self.schedulePreviousConversationPrewarm(url, key: key, attempt: attempt + 1) }
                return
            }

            self.cacheActiveConversationIfNeeded()
            guard !self.warmConversationCache.containsKey(key) else { return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore
            let preload = self.makeWebView(configuration: configuration)
            preload.navigationDelegate = nil
            preload.uiDelegate = nil
            self.warmConversationCache.store(preload, for: key, protected: false)
            self.disposeEvictedViews(self.warmConversationCache.evictIfNeeded(excluding: self.activeConversationKey))
            preload.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
            self.logger.debug("Prewarming previous conversation path")
        }
        warmPreloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func openConversationFast(_ url: URL) {
        guard let key = AppSecurityPolicy.conversationKey(for: url), !isPopup else {
            load(url)
            return
        }
        let started = Date()
        warmPreloadWorkItem?.cancel()
        warmPreloadWorkItem = nil
        cacheActiveConversationIfNeeded()

        if let cached = warmConversationCache.view(for: key) {
            switchToConversationView(cached, key: key)
            lastTrustedURL = url
            SessionCheckpoint.save(url)
            lastConversationOpenMode = "warm"
            lastConversationOpenDuration = Date().timeIntervalSince(started)
            pendingColdConversationKey = nil
            pendingColdOpenStartedAt = nil
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        let destination = makeWebView(configuration: configuration)
        warmConversationCache.store(destination, for: key, protected: false)
        disposeEvictedViews(warmConversationCache.evictIfNeeded(excluding: key))
        switchToConversationView(destination, key: key)
        lastConversationOpenMode = "protected-cold"
        lastConversationOpenDuration = nil
        pendingColdConversationKey = key
        pendingColdOpenStartedAt = started
        loadTrustedURL(url, cachePolicy: .useProtocolCachePolicy)
    }

    private func switchToConversationView(_ destination: WKWebView, key: String) {
        guard destination !== webView else {
            activeConversationKey = key
            return
        }
        let previous = webView!
        let previousWasCached = warmConversationCache.contains(previous)
        heartbeatGeneration &+= 1
        heartbeatInFlight = false
        cancelHeartbeatTimeout()
        cancelNavigationWatchdog()
        previous.navigationDelegate = nil
        previous.uiDelegate = nil

        destination.navigationDelegate = self
        destination.uiDelegate = self
        destination.frame = previous.frame
        destination.autoresizingMask = [.width, .height]
        webView = destination
        window.contentView = destination
        activeConversationKey = key
        resetActiveViewMetrics()
        supervisor.navigationFinished()
        updateWindowTitle()
        scheduleHeartbeat(after: 0.15)
        if !previousWasCached { disposeWebView(previous) }
    }

    private func resetActiveViewMetrics() {
        lastDOMNodeCount = 0
        lastTurnShellCount = 0
        lastMountedRoleCount = 0
        lastRawRoleCount = 0
        lastHiddenTurnCount = 0
        lastPerformanceMode = "native"
        lastIsGenerating = false
        lastGenerationReason = "none"
        lastComposerFocused = false
        lastNearBottom = true
        lastActivityTotal = 0
        lastReasoningCount = 0
        lastToolCount = 0
        lastDetailCount = 0
        lastErrorCount = 0
        lastArtifactCount = 0
        lastCodeCount = 0
        lastTableCount = 0
        lastMediaCount = 0
        lastOptimizerScanMs = 0
        lastHiddenActivityCount = 0
        lastActivityMode = "all"
    }

    private func disposeWebView(_ view: WKWebView) {
        guard view !== webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    private func disposeEvictedViews(_ views: [WKWebView]) {
        views.forEach(disposeWebView)
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

    private func performPerformanceRefresh(reason: String) {
        guard !isClosed, !isPopup else { return }
        logger.notice("Performance refresh reason=\(reason, privacy: .public)")
        rebuildWebView()
    }

    private func rebuildWebView() {
        guard !isClosed else { return }
        let target = trustedCurrentURL() ?? lastTrustedURL
        let conversationKey = AppSecurityPolicy.conversationKey(for: target)
        let oldView = webView!
        let dataStore = oldView.configuration.websiteDataStore

        warmConversationCache.remove(view: oldView)
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
        if let conversationKey {
            warmConversationCache.store(replacement, for: conversationKey, protected: false)
            activeConversationKey = conversationKey
        } else {
            activeConversationKey = nil
        }
        disposeWebView(oldView)
        disposeEvictedViews(warmConversationCache.evictIfNeeded(excluding: conversationKey))

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

    private func startMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.warmPreloadWorkItem?.cancel()
            self.warmPreloadWorkItem = nil
            let evicted = self.warmConversationCache.evictInactive(excluding: self.webView)
            self.disposeEvictedViews(evicted)
            if !evicted.isEmpty {
                self.logger.notice("Evicted \(evicted.count) warm conversation view(s) under memory pressure")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func stopMemoryPressureMonitor() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
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

        if !force, lastIsGenerating, let lastHeartbeatStartedAt, Date().timeIntervalSince(lastHeartbeatStartedAt) < 15 { return }

        let snapshot = supervisor.snapshot()
        guard snapshot.isOnline,
              snapshot.state != .waitingForNetwork,
              snapshot.state != .recovering,
              snapshot.state != .failed else { return }

        heartbeatGeneration += 1
        lastHeartbeatStartedAt = Date()
        let generation = heartbeatGeneration
        heartbeatInFlight = true
        let started = Date()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.heartbeatInFlight, self.heartbeatGeneration == generation else { return }
            self.heartbeatInFlight = false
            let action = self.supervisor.heartbeatTimedOut(isGenerating: self.lastIsGenerating)
            self.performRecovery(action, reason: self.lastIsGenerating ? "heartbeat timeout during generation" : "heartbeat timeout")
        }
        heartbeatTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)

        let measurePerformance = heartbeatGeneration % 5 == 0
        let script = """
        (() => {
          const b = document.body;
          const report = {ready:document.readyState,hasBody:!!b,children:b ? b.children.length : 0,challenge:location.pathname.startsWith('/cdn-cgi/')};
          const perf = window.__chatgptStablePerf?.snapshot?.() || null;
          const active = document.activeElement;
          report.composerFocused = !!active && (active.tagName === 'TEXTAREA' || active.getAttribute?.('contenteditable') === 'true');
          if (perf) {
            report.turnShells = perf.shells;
            report.rawRoles = perf.roles;
            report.mountedRoles = perf.visibleRoles;
            report.hiddenTurns = perf.hidden;
            report.performanceMode = perf.mode;
            report.generating = perf.generating;
            report.generationReason = perf.generationReason;
            report.nearBottom = perf.nearBottom;
            report.activityTotal = perf.activityTotal;
            report.reasoningCount = perf.reasoningCount;
            report.toolCount = perf.toolCount;
            report.detailCount = perf.detailCount;
            report.errorCount = perf.errorCount;
            report.artifactCount = perf.artifactCount;
            report.codeCount = perf.codeCount;
            report.tableCount = perf.tableCount;
            report.mediaCount = perf.mediaCount;
            report.scanMs = perf.scanMs;
            report.hiddenActivities = perf.hiddenActivities;
            report.activityMode = perf.activityMode;
          }
          if (\(measurePerformance ? "true" : "false") && b) {
            const nodeCount = document.getElementsByTagName('*').length;
            report.domNodes = nodeCount;
            window.__chatgptStablePerf?.pressure?.(nodeCount);
          }
          return report;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, self.heartbeatInFlight, self.heartbeatGeneration == generation else { return }
            self.heartbeatInFlight = false
            self.cancelHeartbeatTimeout()

            guard error == nil, let report = value as? [String: Any] else {
                let action = self.supervisor.heartbeatTimedOut(isGenerating: self.lastIsGenerating)
                self.performRecovery(action, reason: self.lastIsGenerating ? "heartbeat evaluation stalled during generation" : "heartbeat evaluation failed")
                return
            }

            let hasBody = report["hasBody"] as? Bool ?? false
            let children = (report["children"] as? NSNumber)?.intValue ?? 0
            let challenge = report["challenge"] as? Bool ?? false
            if let count = (report["domNodes"] as? NSNumber)?.intValue { self.lastDOMNodeCount = count }
            if let count = (report["turnShells"] as? NSNumber)?.intValue { self.lastTurnShellCount = count }
            if let count = (report["mountedRoles"] as? NSNumber)?.intValue { self.lastMountedRoleCount = count }
            if let count = (report["rawRoles"] as? NSNumber)?.intValue { self.lastRawRoleCount = count }
            if let count = (report["hiddenTurns"] as? NSNumber)?.intValue { self.lastHiddenTurnCount = count }
            if let mode = report["performanceMode"] as? String { self.lastPerformanceMode = mode }
            if let generating = report["generating"] as? Bool { self.lastIsGenerating = generating }
            if let reason = report["generationReason"] as? String { self.lastGenerationReason = reason }
            if let focused = report["composerFocused"] as? Bool { self.lastComposerFocused = focused }
            if let nearBottom = report["nearBottom"] as? Bool { self.lastNearBottom = nearBottom }
            if let count = (report["activityTotal"] as? NSNumber)?.intValue { self.lastActivityTotal = count }
            if let count = (report["reasoningCount"] as? NSNumber)?.intValue { self.lastReasoningCount = count }
            if let count = (report["toolCount"] as? NSNumber)?.intValue { self.lastToolCount = count }
            if let count = (report["detailCount"] as? NSNumber)?.intValue { self.lastDetailCount = count }
            if let count = (report["errorCount"] as? NSNumber)?.intValue { self.lastErrorCount = count }
            if let count = (report["artifactCount"] as? NSNumber)?.intValue { self.lastArtifactCount = count }
            if let count = (report["codeCount"] as? NSNumber)?.intValue { self.lastCodeCount = count }
            if let count = (report["tableCount"] as? NSNumber)?.intValue { self.lastTableCount = count }
            if let count = (report["mediaCount"] as? NSNumber)?.intValue { self.lastMediaCount = count }
            if let ms = (report["scanMs"] as? NSNumber)?.doubleValue { self.lastOptimizerScanMs = ms }
            if let count = (report["hiddenActivities"] as? NSNumber)?.intValue { self.lastHiddenActivityCount = count }
            if let mode = report["activityMode"] as? String { self.lastActivityMode = mode }
            if let currentURL = self.webView.url,
               let currentKey = AppSecurityPolicy.conversationKey(for: currentURL) {
                if currentKey != self.activeConversationKey {
                    self.warmConversationCache.remove(view: self.webView)
                    self.warmConversationCache.store(self.webView, for: currentKey, protected: self.lastIsGenerating)
                    self.activeConversationKey = currentKey
                    self.disposeEvictedViews(self.warmConversationCache.evictIfNeeded(excluding: currentKey))
                } else {
                    self.warmConversationCache.setProtected(self.lastIsGenerating, for: currentKey)
                }
            } else if self.activeConversationKey != nil {
                self.warmConversationCache.remove(view: self.webView)
                self.activeConversationKey = nil
            }
            if let pendingKey = self.pendingColdConversationKey,
               let startedAt = self.pendingColdOpenStartedAt,
               AppSecurityPolicy.conversationKey(for: self.webView.url ?? self.lastTrustedURL) == pendingKey,
               (self.lastMountedRoleCount > 0 || self.lastTurnShellCount > 0) {
                self.lastConversationOpenDuration = Date().timeIntervalSince(startedAt)
                self.pendingColdConversationKey = nil
                self.pendingColdOpenStartedAt = nil
            }
            let renderable = challenge || (hasBody && children > 0)
            let latency = Date().timeIntervalSince(started)
            let action = self.supervisor.heartbeatSucceeded(latency: latency, renderable: renderable)
            self.performRecovery(action, reason: renderable ? "heartbeat healthy" : "blank render")
            if action == .none, renderable {
                let performanceAction = self.pressureController.observe(
                    PerformancePressureSample(
                        domNodes: self.lastDOMNodeCount,
                        mountedRoles: self.lastMountedRoleCount,
                        heartbeatLatency: latency,
                        optimizerScanLatency: self.lastOptimizerScanMs / 1000,
                        isGenerating: self.lastIsGenerating,
                        composerFocused: self.lastComposerFocused,
                        nearBottom: self.lastNearBottom
                    ),
                    structuralMeasurement: measurePerformance
                )
                if performanceAction == .refreshNow {
                    self.performPerformanceRefresh(reason: "sustained frontend pressure")
                }
            }
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
        case .healthy:
            if lastIsGenerating { suffix = "Running" }
            else if pressureController.snapshot().level == .severe { suffix = "Heavy conversation" }
            else { suffix = "" }
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

    func testCacheCurrentConversation(as url: URL, protected: Bool = false) {
        guard let key = AppSecurityPolicy.conversationKey(for: url) else { return }
        warmConversationCache.store(webView, for: key, protected: protected)
        activeConversationKey = key
        lastTrustedURL = url
    }

    func testSeedWarmConversation(_ url: URL, html: String) -> WKWebView? {
        guard let key = AppSecurityPolicy.conversationKey(for: url) else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        let view = makeWebView(configuration: configuration)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.loadHTMLString(html, baseURL: url)
        warmConversationCache.store(view, for: key, protected: false)
        return view
    }

    func testOpenConversation(_ url: URL) {
        openConversationFast(url)
    }

    func testWarmCacheStats() -> WarmConversationCache.Stats {
        warmConversationCache.stats()
    }

    func testLastConversationOpenMode() -> String { lastConversationOpenMode }

    func testWarmCacheDecision(for path: String) -> String {
        warmCacheDecision(for: path)
    }

    func testPrewarmConversation(for path: String) -> String {
        prewarmConversation(for: path)
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

        if url.scheme?.lowercased() == AppSecurityPolicy.internalConversationScheme {
            guard navigationAction.targetFrame?.isMainFrame != false,
                  let target = AppSecurityPolicy.conversationTarget(fromInternalURL: url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
            openConversationFast(target)
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
        warmPreloadWorkItem?.cancel()
        warmPreloadWorkItem = nil
        stopMemoryPressureMonitor()
        cancelNavigationWatchdog()
        networkMonitor.stop()
        disposeEvictedViews(warmConversationCache.drain())
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
