import AppKit
import WebKit
import XCTest
@testable import ChatGPTStable

@MainActor
final class BrowserIntegrationTests: XCTestCase {
    func testStrongRecoveryReplacesWebViewButPreservesOpaqueDataStore() {
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        let oldView = controller.webView!
        let oldStore = oldView.configuration.websiteDataStore

        controller.testRebuildWebView()

        XCTAssertFalse(oldView === controller.webView)
        XCTAssertTrue(oldStore === controller.webView.configuration.websiteDataStore)
        controller.window.close()
    }

    func testBlankDocumentIsDetectedWithoutReadingPageText() async throws {
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        controller.testLoadBlankDocument()
        try await Task.sleep(nanoseconds: 400_000_000)

        controller.testRunHeartbeat()
        try await Task.sleep(nanoseconds: 400_000_000)

        let snapshot = controller.testHealthSnapshot()
        XCTAssertEqual(snapshot.lastFailure, .blankRender)
        XCTAssertGreaterThanOrEqual(snapshot.totalRecoveries, 1)
        controller.window.close()
    }

    func testWarmConversationReopenReusesLiveWebView() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        let urlA = URL(string: "https://chatgpt.com/c/cache-a")!
        let urlB = URL(string: "https://chatgpt.com/c/cache-b")!
        controller.webView.loadHTMLString("<html><body><section data-turn-id='a'><div data-message-author-role='assistant'>a</div></section></body></html>", baseURL: urlA)
        try await Task.sleep(nanoseconds: 500_000_000)
        let viewA = controller.webView!
        controller.testCacheCurrentConversation(as: urlA)
        let viewB = try XCTUnwrap(controller.testSeedWarmConversation(urlB, html: "<html><body><section data-turn-id='b'><div data-message-author-role='assistant'>b</div></section></body></html>"))
        try await Task.sleep(nanoseconds: 300_000_000)

        controller.testOpenConversation(urlB)
        XCTAssertTrue(controller.webView === viewB)
        XCTAssertEqual(controller.testLastConversationOpenMode(), "warm")
        controller.testOpenConversation(urlA)
        XCTAssertTrue(controller.webView === viewA)
        XCTAssertEqual(controller.testWarmCacheStats().count, 2)
        XCTAssertGreaterThanOrEqual(controller.testWarmCacheStats().hits, 2)
        controller.window.close()
    }

    func testSidebarConversationClickUsesWarmCacheRoute() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        let urlA = URL(string: "https://chatgpt.com/c/click-a")!
        let urlB = URL(string: "https://chatgpt.com/c/click-b")!
        controller.webView.loadHTMLString("<html><body><a id='chat-link' href='/c/click-b'>open</a><section data-turn-id='a'><div data-message-author-role='assistant'>a</div></section></body></html>", baseURL: urlA)
        try await Task.sleep(nanoseconds: 600_000_000)
        controller.testCacheCurrentConversation(as: urlA)
        let viewB = try XCTUnwrap(controller.testSeedWarmConversation(urlB, html: "<html><body><section data-turn-id='b'><div data-message-author-role='assistant'>b</div></section></body></html>"))
        try await Task.sleep(nanoseconds: 250_000_000)

        _ = try await Self.evaluate("document.getElementById('chat-link').click()", in: controller.webView)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(controller.webView === viewB)
        XCTAssertEqual(controller.testLastConversationOpenMode(), "warm")
        controller.window.close()
    }

    func testColdSidebarConversationClickFallsBackToPageHandler() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        let sourceURL = URL(string: "https://chatgpt.com/c/cold-source")!
        controller.webView.loadHTMLString("""
        <html><body data-chat-click='0'>
          <a id='cold-link' href='/c/cold-target'>open</a>
          <section data-turn-id='a'><div data-message-author-role='assistant'>a</div></section>
          <script>
            document.addEventListener('click', e => {
              if (e.target.closest('#cold-link')) {
                e.preventDefault();
                document.body.setAttribute('data-chat-click','1');
              }
            }, true);
          </script>
        </body></html>
        """, baseURL: sourceURL)
        try await Task.sleep(nanoseconds: 600_000_000)
        controller.testCacheCurrentConversation(as: sourceURL)

        _ = try await Self.evaluate("document.getElementById('cold-link').click()", in: controller.webView)
        try await Task.sleep(nanoseconds: 350_000_000)
        let clicked = try await Self.evaluate("document.body.getAttribute('data-chat-click')", in: controller.webView) as? String
        XCTAssertEqual(clicked, "1")
        XCTAssertEqual(controller.testLastConversationOpenMode(), "cold-spa")
        controller.window.close()
    }

    func testWarmCacheBridgeIsHiddenFromPageWorld() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: "https://chatgpt.com/")!)
        try await Task.sleep(nanoseconds: 300_000_000)
        let visible = try await Self.evaluate("!!window.webkit?.messageHandlers?.warmConversationCache", in: controller.webView) as? Bool
        XCTAssertEqual(visible, false)
        controller.window.close()
    }

    func testOpeningColdChatPreservesActivelyGeneratingSourceRenderer() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        let sourceURL = URL(string: "https://chatgpt.com/c/running-source")!
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 4, generating: true), baseURL: sourceURL)
        try await Task.sleep(nanoseconds: 700_000_000)
        controller.testCacheCurrentConversation(as: sourceURL)
        controller.testRunHeartbeat()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.testWarmCacheDecision(for: "/c/next-chat"), "preserve-current")
        controller.window.close()
    }

    func testIdleHomeCanPrewarmMostRecentConversationDeterministically() {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        let initialCount = controller.testWarmCacheStats().count
        XCTAssertEqual(controller.testPrewarmConversation(for: "/c/prewarm-recent"), "scheduled")
        XCTAssertEqual(controller.testWarmCacheStats().count, initialCount + 1)
        XCTAssertEqual(controller.testPrewarmConversation(for: "/c/prewarm-recent"), "warm")
        XCTAssertEqual(controller.testWarmCacheStats().count, initialCount + 1)
        controller.window.close()
    }

    func testTerminalModeDropsIdlePreviousConversationOnSwitch() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        let urlA = URL(string: "https://chatgpt.com/c/terminal-a")!
        let urlB = URL(string: "https://chatgpt.com/c/terminal-b")!
        controller.webView.loadHTMLString("<html><body><section data-turn-id='a'><div data-message-author-role='assistant'>a</div></section></body></html>", baseURL: urlA)
        try await Task.sleep(nanoseconds: 400_000_000)
        let viewA = controller.webView!
        controller.testCacheCurrentConversation(as: urlA)
        let viewB = try XCTUnwrap(controller.testSeedWarmConversation(urlB, html: "<html><body><section data-turn-id='b'><div data-message-author-role='assistant'>b</div></section></body></html>"))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(controller.testWarmCacheStats().count, 2)

        controller.testOpenConversation(urlB)
        XCTAssertTrue(controller.webView === viewB)
        XCTAssertFalse(controller.webView === viewA)
        XCTAssertEqual(controller.testWarmCacheStats().count, 1)
        controller.window.close()
    }

    func testTerminalSimpleConversationAllocatesNoIdleOverlayControls() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 4), baseURL: URL(string: "https://chatgpt.com/c/simple")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        let values = try await Self.evaluate("(() => ({rail:!!document.getElementById('chatgpt-stable-activity-rail'), history:!!document.getElementById('chatgpt-stable-history-control')}))()", in: controller.webView) as? [String: Any]
        XCTAssertEqual(values?["rail"] as? Bool, false)
        XCTAssertEqual(values?["history"] as? Bool, false)
        controller.window.close()
    }

    func testTerminalModeDoesNotPrewarmIdleConversation() {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        XCTAssertEqual(controller.currentInterfaceMode(), .terminal)
        XCTAssertEqual(controller.testPrewarmConversation(for: "/c/prewarm-recent"), "ignored")
        XCTAssertEqual(controller.testWarmCacheStats().count, 0)
        controller.window.close()
    }

    func testConversationInitialOpenLandsAtNewestTurn() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversationWithoutInitialScroll(turns: 40), baseURL: URL(string: "https://chatgpt.com/c/latest")!)
        try await Task.sleep(nanoseconds: 900_000_000)
        let distance = try await Self.evaluate("(() => { const r=document.getElementById('scroll'); return r.scrollHeight-r.scrollTop-r.clientHeight; })()", in: controller.webView) as? NSNumber
        XCTAssertLessThanOrEqual(abs(distance?.doubleValue ?? 1000), 2)
        controller.window.close()
    }

    func testPerformanceOptimizerStaysNativeForSmallMountedHistory() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 8), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual(snapshot["mode"] as? String, "native")
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 0)
        controller.window.close()
    }


    func testElevatedPressureTightensConversationTail() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 40), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        _ = try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(10000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 400_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 12)
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 28)
        controller.window.close()
    }

    func testSeverePressureTightensConversationTailFurther() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 40), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        _ = try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(20000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 400_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 8)
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 32)
        controller.window.close()
    }

    func testPerformanceOptimizerVirtualizesLargeMountedHistory() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 40), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual(snapshot["mode"] as? String, "tail")
        XCTAssertGreaterThan((snapshot["hidden"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertLessThanOrEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue ?? 100, 20)
        controller.window.close()
    }

    func testPerformanceOptimizerUsesStreamingModeUnderPressure() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 8, generating: true), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        _ = try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(10000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 400_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual(snapshot["mode"] as? String, "streaming")
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 4)
        controller.window.close()
    }




    func testLongVirtualizedConversationGetsConstantSizeThreadNavigator() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticShellOnlyConversation(turns: 120), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)
        let values = try await Self.evaluate("(() => { const r=document.getElementById('chatgpt-stable-thread-range'); return {rail:!!document.getElementById('chatgpt-stable-activity-rail'), max:r?.max, controls:document.querySelectorAll('#chatgpt-stable-thread-nav input').length, rows:document.querySelectorAll('#chatgpt-stable-activity-list button').length}; })()", in: controller.webView) as? [String: Any]
        XCTAssertEqual(values?["rail"] as? Bool, true)
        XCTAssertEqual(values?["max"] as? String, "119")
        XCTAssertEqual((values?["controls"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((values?["rows"] as? NSNumber)?.intValue, 0)
        controller.window.close()
    }

    func testModernPersistentShellAndFallbackRoleSelectorsAreRecognized() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString("<html><body><div data-turn-id-container='x'><div data-role='assistant'><details data-testid='tool-browser'><summary>x</summary><div>x</div></details></div></div></body></html>", baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["shells"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["roles"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 1)
        controller.window.close()
    }

    func testLeanInterfaceIndexesActivityWithoutReadingContent() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticActivityConversation(), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual((snapshot["reasoningCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["toolCount"] as? NSNumber)?.intValue, 1)
        let firstKinds = try await Self.evaluate("Array.from(document.querySelectorAll('#chatgpt-stable-activity-list button')).slice(0,2).map(x=>x.innerText)", in: controller.webView) as? [String]
        XCTAssertTrue(firstKinds?.contains(where: { $0.hasPrefix("Reasoning") }) == true)
        XCTAssertTrue(firstKinds?.contains(where: { $0.hasPrefix("Search") }) == true)
        XCTAssertEqual((snapshot["codeCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["tableCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["mediaCount"] as? NSNumber)?.intValue, 3)
        let railExists = try await Self.evaluate("!!document.getElementById('chatgpt-stable-activity-rail')", in: controller.webView) as? Bool
        XCTAssertEqual(railExists, true)
        controller.window.close()
    }

    func testLeanInterfaceDisablesMotionAtDocumentStart() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString("<html><body><div id='motion' style='transition: all 4s; animation: pulse 4s infinite'>x</div></body></html>", baseURL: URL(string: "https://chatgpt.com/")!)
        try await Task.sleep(nanoseconds: 500_000_000)
        let duration = try await Self.evaluate("getComputedStyle(document.getElementById('motion')).transitionDuration", in: controller.webView) as? String
        XCTAssertTrue(duration == "0.001ms" || duration == "0s" || duration == "0.000001s")
        controller.window.close()
    }

    private static func syntheticConversationWithoutInitialScroll(turns: Int) -> String {
        let items = (0..<turns).map { index in
            "<section data-turn-id='t\(index)' data-testid='conversation-turn-\(index)' style='height:70px'><div data-message-author-role='assistant'>x</div></section>"
        }.joined()
        return "<html><body><div id='scroll' style='height:300px;overflow-y:auto'>\(items)</div></body></html>"
    }

    private static func syntheticConversation(turns: Int, generating: Bool = false) -> String {
        let items = (0..<turns).map { index in
            "<section data-turn-id='t\(index)' data-testid='conversation-turn-\(index)' style='height:70px'><div data-message-author-role='assistant'>x</div></section>"
        }.joined()
        let stop = generating ? "<button data-testid='stop-button' aria-busy='true'>stop</button>" : ""
        return """
        <html><body><div id='scroll' style='height:300px;overflow-y:auto'>\(items)\(stop)</div>
        <script>addEventListener('load',()=>{const s=document.getElementById('scroll');s.scrollTop=s.scrollHeight;});</script>
        </body></html>
        """
    }



    func testCompletedTurnGetsContainmentLazyMediaAndOneTimeDetailCollapse() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticCompletedTurnFixture(), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)

        let values = try await Self.evaluate("(() => { const turn=document.querySelector('[data-testid=conversation-turn-0]'); const detail=turn.querySelector('details'); const img=turn.querySelector('img'); const form=document.querySelector('form'); return {complete:turn.getAttribute('data-chatgpt-stable-complete'), open:detail.open, marked:detail.getAttribute('data-chatgpt-stable-autocollapsed'), loading:img.getAttribute('loading'), decoding:img.getAttribute('decoding'), composer:form.getAttribute('data-chatgpt-stable-composer'), turnBlocked:turn.classList.contains('rr-block'), composerBlocked:form.classList.contains('rr-block'), contain:getComputedStyle(turn).contain}; })()", in: controller.webView) as? [String: Any]
        XCTAssertEqual(values?["complete"] as? String, "1")
        XCTAssertEqual(values?["open"] as? Bool, false)
        XCTAssertEqual(values?["marked"] as? String, "1")
        XCTAssertEqual(values?["loading"] as? String, "lazy")
        XCTAssertEqual(values?["decoding"] as? String, "async")
        XCTAssertEqual(values?["composer"] as? String, "1")
        XCTAssertEqual(values?["turnBlocked"] as? Bool, true)
        XCTAssertEqual(values?["composerBlocked"] as? Bool, true)
        XCTAssertTrue((values?["contain"] as? String)?.contains("style") == true)
        controller.window.close()
    }




    func testLeanInterfaceCanBeDisabledAndReenabledByRebuildingWebView() {
        let controller = BrowserWindowController()
        XCTAssertGreaterThan(controller.webView.configuration.userContentController.userScripts.count, 0)
        XCTAssertTrue(controller.webView.configuration.mediaTypesRequiringUserActionForPlayback.contains(.video))
        XCTAssertFalse(controller.webView.configuration.mediaTypesRequiringUserActionForPlayback.contains(.audio))
        let first = controller.webView!
        controller.setLeanInterfaceEnabled(false)
        XCTAssertFalse(first === controller.webView)
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 0)
        let second = controller.webView!
        controller.setLeanInterfaceEnabled(true)
        XCTAssertFalse(second === controller.webView)
        XCTAssertGreaterThan(controller.webView.configuration.userContentController.userScripts.count, 0)
        controller.window.close()
    }

    func testTerminalInterfaceIsDefaultAndModeSwitchingRebuildsWebView() {
        let controller = BrowserWindowController()
        XCTAssertEqual(controller.currentInterfaceMode(), .terminal)
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 3)

        let terminalView = controller.webView!
        controller.setInterfaceMode(.lean)
        XCTAssertFalse(terminalView === controller.webView)
        XCTAssertEqual(controller.currentInterfaceMode(), .lean)
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 2)

        let leanView = controller.webView!
        controller.setInterfaceMode(.standard)
        XCTAssertFalse(leanView === controller.webView)
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 0)

        controller.setInterfaceMode(.terminal)
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 3)
        controller.window.close()
    }

    func testTerminalInterfaceRemovesChromeButKeepsSendControlAndRestoresChats() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString("""
        <html><body>
          <aside class='dframe-sidebar'>history</aside>
          <div data-testid='chat-header'>header</div>
          <main>
            <section data-turn-id='t0' data-testid='conversation-turn-0'>
              <div data-message-author-role='user'><div data-user-message-bubble='true'>prompt</div></div>
              <div data-message-action-bar>actions</div>
            </section>
            <form><div id='prompt-textarea' data-lexical-editor='true' contenteditable='true'></div><button data-testid='composer-plus-btn'>plus</button><button data-testid='send-button'>send</button></form>
          </main>
        </body></html>
        """, baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)

        let values = try await Self.evaluate("(() => ({terminal:document.documentElement.getAttribute('data-chatgpt-stable-terminal'), sidebar:getComputedStyle(document.querySelector('aside')).display, header:getComputedStyle(document.querySelector('[data-testid=chat-header]')).display, plus:getComputedStyle(document.querySelector('[data-testid=composer-plus-btn]')).display, send:getComputedStyle(document.querySelector('[data-testid=send-button]')).display, actions:getComputedStyle(document.querySelector('[data-message-action-bar]')).display, mono:getComputedStyle(document.querySelector('[data-message-author-role=user]')).fontFamily, toggle:!!document.getElementById('chatgpt-stable-terminal-sidebar-toggle')}))()", in: controller.webView) as? [String: Any]
        XCTAssertEqual(values?["terminal"] as? String, "1")
        XCTAssertEqual(values?["sidebar"] as? String, "none")
        XCTAssertEqual(values?["header"] as? String, "none")
        XCTAssertEqual(values?["plus"] as? String, "none")
        XCTAssertNotEqual(values?["send"] as? String, "none")
        XCTAssertEqual(values?["actions"] as? String, "none")
        XCTAssertTrue((values?["mono"] as? String)?.lowercased().contains("mono") == true || (values?["mono"] as? String)?.contains("Menlo") == true)
        XCTAssertEqual(values?["toggle"] as? Bool, true)

        _ = try await Self.evaluate("document.getElementById('chatgpt-stable-terminal-sidebar-toggle').click()", in: controller.webView)
        let sidebarAfter = try await Self.evaluate("getComputedStyle(document.querySelector('aside')).display", in: controller.webView) as? String
        XCTAssertNotEqual(sidebarAfter, "none")
        controller.window.close()
    }

    func testTerminalConversationTailIsMoreAggressiveThanLean() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticConversation(turns: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)
        var snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 12)
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 18)

        _ = try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(10000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 8)
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 22)

        _ = try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(20000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 6)
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 24)
        controller.window.close()
    }

    func testTerminalCollapsedActivityRailDoesNotBuildRowsUntilOpened() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)

        var rows = try await Self.evaluate("document.querySelectorAll('#chatgpt-stable-activity-list button').length", in: controller.webView) as? NSNumber
        XCTAssertEqual(rows?.intValue, 0)
        _ = try await Self.evaluate("document.getElementById('chatgpt-stable-activity-header').click()", in: controller.webView)
        try await Task.sleep(nanoseconds: 200_000_000)
        rows = try await Self.evaluate("document.querySelectorAll('#chatgpt-stable-activity-list button').length", in: controller.webView) as? NSNumber
        XCTAssertGreaterThan(rows?.intValue ?? 0, 0)
        controller.window.close()
    }

    func testTerminalActivityKeepsEightCompletedAndFourStreamingCards() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 14), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)
        var snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 6)
        XCTAssertEqual(snapshot["activityMode"] as? String, "compact")

        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 14, generating: true), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)
        snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 10)
        XCTAssertEqual(snapshot["activityMode"] as? String, "streaming")
        controller.window.close()
    }

    func testShowAllActivityControlRestoresParkedCards() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)
        var snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 18)
        _ = try await Self.evaluate("document.getElementById('chatgpt-stable-activity-reveal').click()", in: controller.webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(snapshot["activityMode"] as? String, "all")
        _ = try await Self.evaluate("document.getElementById('chatgpt-stable-activity-reveal').click()", in: controller.webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 18)
        XCTAssertEqual(snapshot["activityMode"] as? String, "compact")
        controller.window.close()
    }


    func testLeanStructuralScanStaysBoundedOnLargeNoisyDOM() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticNoisyConversation(noiseNodes: 12_000, activityCount: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        let scanMs = (snapshot["scanMs"] as? NSNumber)?.doubleValue ?? 10_000
        XCTAssertLessThan(scanMs, 250, "lean structural scan exceeded its 250 ms regression budget")
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 30)
        controller.window.close()
    }





    func testCompletedAgentTurnStaysCompactAndCollapsesOldDisclosuresOnce() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticOpenToolConversation(activityCount: 14), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)
        var snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(snapshot["activityMode"] as? String, "compact")
        let states = try await Self.evaluate("Array.from(document.querySelectorAll('details')).map(x=>x.open)", in: controller.webView) as? [Bool]
        XCTAssertEqual(states?.first, false)
        XCTAssertEqual(states?.suffix(3).allSatisfy { $0 }, true)
        _ = try await Self.evaluate("document.querySelectorAll('details')[5].open=true", in: controller.webView)
        _ = try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(1000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 250_000_000)
        let reopened = try await Self.evaluate("document.querySelectorAll('details')[5].open", in: controller.webView) as? Bool
        XCTAssertEqual(reopened, true)
        snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 14)
        controller.window.close()
    }

    func testArtifactActivityStaysVisibleDuringCompaction() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 30, artifactIndex: 1), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["artifactCount"] as? NSNumber)?.intValue, 1)
        let hidden = try await Self.evaluate("document.querySelector('[data-testid=generated-file-1]').getAttribute('data-chatgpt-stable-activity-hidden')", in: controller.webView) as? String
        XCTAssertNil(hidden)
        controller.window.close()
    }

    func testErrorActivityStaysVisibleDuringCompaction() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 30, errorIndex: 0), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["errorCount"] as? NSNumber)?.intValue, 1)
        let errorHidden = try await Self.evaluate("document.querySelector('[data-testid=tool-error-0]').getAttribute('data-chatgpt-stable-activity-hidden')", in: controller.webView) as? String
        XCTAssertNil(errorHidden)
        controller.window.close()
    }

    func testCompletedErrorDisclosureIsNotAutoCollapsed() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticCompletedErrorFixture(), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)
        let open = try await Self.evaluate("document.querySelector('[data-testid=tool-error-card]').open", in: controller.webView) as? Bool
        XCTAssertEqual(open, true)
        controller.window.close()
    }

    func testActivityRailKeepsOnlyLatestFortyRowsUntilExpanded() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 90), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        let initialRowsReady = try await Self.waitForJavaScript("document.querySelectorAll('#chatgpt-stable-activity-list button').length === 41", in: controller.webView)
        XCTAssertTrue(initialRowsReady)
        _ = try await Self.evaluate("document.querySelector('#chatgpt-stable-activity-list button').click()", in: controller.webView)
        let firstExpansionReady = try await Self.waitForJavaScript("document.querySelectorAll('#chatgpt-stable-activity-list button').length === 81", in: controller.webView)
        XCTAssertTrue(firstExpansionReady)
        _ = try await Self.evaluate("document.querySelector('#chatgpt-stable-activity-list button').click()", in: controller.webView)
        let secondExpansionReady = try await Self.waitForJavaScript("document.querySelectorAll('#chatgpt-stable-activity-list button').length === 90", in: controller.webView)
        XCTAssertTrue(secondExpansionReady)
        controller.window.close()
    }

    func testActivityVirtualizationParksOlderCardsButKeepsRailIndex() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 18)
        XCTAssertEqual(snapshot["activityMode"] as? String, "compact")
        let header = try await Self.evaluate("document.getElementById('chatgpt-stable-activity-header').innerText", in: controller.webView) as? String
        XCTAssertTrue(header?.contains("parked 18") == true)
        XCTAssertTrue(header?.contains("compact") == true)
        let bottomDistance = try await Self.evaluate("(() => { const r=document.getElementById('scroll'); return r.scrollHeight-r.scrollTop-r.clientHeight; })()", in: controller.webView) as? NSNumber
        XCTAssertLessThanOrEqual(abs(bottomDistance?.doubleValue ?? 1000), 2)
        let railRows = try await Self.evaluate("document.querySelectorAll('#chatgpt-stable-activity-list button').length", in: controller.webView) as? NSNumber
        XCTAssertEqual(railRows?.intValue, 30)
        controller.window.close()
    }

    func testStreamingActivityVirtualizationKeepsLatestSix() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 14, generating: true), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 8)
        XCTAssertEqual(snapshot["activityMode"] as? String, "streaming")
        controller.window.close()
    }



    func testCompletedTurnActionsAreVisuallyDormant() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticActionFixture(), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        let opacity = try await Self.evaluate("getComputedStyle(document.querySelector('[data-testid=copy-turn-action-button]')).opacity", in: controller.webView) as? String
        XCTAssertEqual(opacity, "0.08")
        controller.window.close()
    }



    func testLeanInterfaceHidesOnlyNonConversationUpsellChrome() async throws {
        let controller = BrowserWindowController()
        controller.setInterfaceMode(.lean)
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticBloatFixture(), baseURL: URL(string: "https://chatgpt.com/")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        let values = try await Self.evaluate("(() => ({outside:document.getElementById('outside').getAttribute('data-chatgpt-stable-bloat-hidden'), inside:document.getElementById('inside').getAttribute('data-chatgpt-stable-bloat-hidden'), normal:document.getElementById('normal').getAttribute('data-chatgpt-stable-bloat-hidden')}))()", in: controller.webView) as? [String: Any]
        XCTAssertEqual(values?["outside"] as? String, "1")
        XCTAssertNil(values?["inside"] as? String)
        XCTAssertNil(values?["normal"] as? String)
        controller.window.close()
    }


    private static func syntheticBloatFixture() -> String {
        """
        <html><body>
          <div id='outside' data-testid='pro-upsell-banner'>upgrade</div>
          <div id='normal' data-testid='important-status-banner'>status</div>
          <section data-turn-id='t0' data-testid='conversation-turn-0'><div data-message-author-role='assistant'><div id='inside' data-testid='tool-upgrade-result'>tool</div></div></section>
        </body></html>
        """
    }

    private static func syntheticActionFixture() -> String {
        """
        <html><body>
          <section data-turn-id='t0' data-testid='conversation-turn-0'><div data-message-author-role='assistant'><button data-testid='copy-turn-action-button'>copy</button></div></section>
          <section data-turn-id='t1' data-testid='conversation-turn-1'><div data-message-author-role='assistant'>latest</div></section>
        </body></html>
        """
    }





    private static func syntheticOpenToolConversation(activityCount: Int) -> String {
        let tools = (0..<activityCount).map { index in
            "<details open data-testid='tool-search-\(index)'><summary>tool</summary><div style='height:20px'>x</div></details>"
        }.joined()
        return "<html><body><div id='scroll' style='height:300px;overflow-y:auto'><section data-turn-id='t0' data-testid='conversation-turn-0' style='min-height:1000px'><div data-message-author-role='assistant'>\(tools)</div></section></div><script>addEventListener('load',()=>{const s=document.getElementById('scroll');s.scrollTop=s.scrollHeight;});</script></body></html>"
    }

    private static func syntheticCompletedErrorFixture() -> String {
        """
        <html><body>
          <section data-turn-id='t0' data-testid='conversation-turn-0'><div data-message-author-role='assistant'><details open data-testid='tool-error-card'><summary>error</summary><div>x</div></details></div></section>
          <section data-turn-id='t1' data-testid='conversation-turn-1'><div data-message-author-role='assistant'>latest</div></section>
        </body></html>
        """
    }

    private static func syntheticShellOnlyConversation(turns: Int) -> String {
        let shells = (0..<turns).map { index in
            "<section data-testid='conversation-turn-\(index)' data-turn='\(index.isMultiple(of: 2) ? "user" : "assistant")' style='height:40px'></section>"
        }.joined()
        return "<html><body>\(shells)</body></html>"
    }

    private static func syntheticNoisyConversation(noiseNodes: Int, activityCount: Int) -> String {
        let noise = String(repeating: "<span class='noise'></span>", count: noiseNodes)
        let tools = (0..<activityCount).map { index in
            "<details data-testid='tool-search-\(index)'><summary>tool</summary><div>x</div></details>"
        }.joined()
        return """
        <html><body>\(noise)<div id='scroll' style='height:300px;overflow-y:auto'><section data-turn-id='t0' data-testid='conversation-turn-0'><div data-message-author-role='assistant'>\(tools)</div></section></div></body></html>
        """
    }

    private static func syntheticToolHeavyConversation(activityCount: Int, generating: Bool = false, errorIndex: Int? = nil, artifactIndex: Int? = nil) -> String {
        let tools = (0..<activityCount).map { index in
            let testID: String
            if index == errorIndex { testID = "tool-error-\(index)" }
            else if index == artifactIndex { testID = "generated-file-\(index)" }
            else { testID = "tool-search-\(index)" }
            return "<details data-testid='\(testID)'><summary>tool</summary><div>x</div></details>"
        }.joined()
        let stop = generating ? "<button data-testid='stop-button' style='width:20px;height:20px'>stop</button>" : ""
        return """
        <html><body><div id='scroll' style='height:300px;overflow-y:auto'>
          <section data-turn-id='t0' data-testid='conversation-turn-0' style='min-height:1000px'><div data-message-author-role='assistant'>\(tools)\(stop)</div></section>
        </div><script>addEventListener('load',()=>{const s=document.getElementById('scroll');s.scrollTop=s.scrollHeight;});</script></body></html>
        """
    }

    private static func syntheticCompletedTurnFixture() -> String {
        """
        <html><body>
          <div id='scroll' style='height:400px;overflow-y:auto'>
            <section data-turn-id='t0' data-testid='conversation-turn-0'>
              <div data-message-author-role='assistant'><details open><summary>x</summary><div>x</div></details><img src='data:image/gif;base64,R0lGODlhAQABAAAAACw='></div>
            </section>
            <section data-turn-id='t1' data-testid='conversation-turn-1'><div data-message-author-role='assistant'>latest</div></section>
          </div>
          <form><div id='prompt-textarea' data-testid='prompt-textarea' contenteditable='true'></div></form>
        </body></html>
        """
    }

    private static func syntheticActivityConversation() -> String {
        """
        <html><body><div id='scroll' style='height:400px;overflow-y:auto'>
          <section data-turn-id='t0' data-testid='conversation-turn-0'>
            <div data-message-author-role='assistant'>
              <details data-testid='reasoning-summary'><summary>r</summary><div>x</div></details>
              <div data-testid='tool-search-result'><button>tool</button></div>
              <pre><code>x</code></pre><table><tr><td>x</td></tr></table><figure><img alt='x' src='data:image/gif;base64,R0lGODlhAQABAAAAACw='></figure><canvas width='10' height='10'></canvas><audio></audio>
            </div>
          </section>
        </div></body></html>
        """
    }

    private static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: value)
            }
        }
    }

    private static func waitForJavaScript(
        _ script: String,
        in webView: WKWebView,
        attempts: Int = 20
    ) async throws -> Bool {
        for _ in 0..<attempts {
            if (try await evaluate(script, in: webView) as? Bool) == true { return true }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    private static func performanceSnapshot(from webView: WKWebView) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("window.__chatgptStablePerf?.snapshot?.() || null") { value, error in
                if let error { continuation.resume(throwing: error); return }
                guard let snapshot = value as? [String: Any] else {
                    continuation.resume(throwing: NSError(domain: "ChatGPTStableTests", code: 1))
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }
}
