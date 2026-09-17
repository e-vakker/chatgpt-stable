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

    func testPerformanceOptimizerVirtualizesLargeMountedHistory() async throws {
        let controller = BrowserWindowController()
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


    func testLeanInterfaceIndexesActivityWithoutReadingContent() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticActivityConversation(), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 800_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((snapshot["reasoningCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["toolCount"] as? NSNumber)?.intValue, 1)
        let firstKinds = try await Self.evaluate("Array.from(document.querySelectorAll('#chatgpt-stable-activity-list button')).slice(0,2).map(x=>x.innerText)", in: controller.webView) as? [String]
        XCTAssertTrue(firstKinds?.contains(where: { $0.hasPrefix("Reasoning") }) == true)
        XCTAssertTrue(firstKinds?.contains(where: { $0.hasPrefix("Search") }) == true)
        XCTAssertEqual((snapshot["codeCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["tableCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((snapshot["mediaCount"] as? NSNumber)?.intValue, 1)
        let railExists = try await Self.evaluate("!!document.getElementById('chatgpt-stable-activity-rail')", in: controller.webView) as? Bool
        XCTAssertEqual(railExists, true)
        controller.window.close()
    }

    func testLeanInterfaceDisablesMotionAtDocumentStart() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString("<html><body><div id='motion' style='transition: all 4s; animation: pulse 4s infinite'>x</div></body></html>", baseURL: URL(string: "https://chatgpt.com/")!)
        try await Task.sleep(nanoseconds: 500_000_000)
        let duration = try await Self.evaluate("getComputedStyle(document.getElementById('motion')).transitionDuration", in: controller.webView) as? String
        XCTAssertTrue(duration == "0.001ms" || duration == "0s" || duration == "0.000001s")
        controller.window.close()
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

    func testShowAllActivityControlRestoresParkedCards() async throws {
        let controller = BrowserWindowController()
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
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticNoisyConversation(noiseNodes: 12_000, activityCount: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        let scanMs = (snapshot["scanMs"] as? NSNumber)?.doubleValue ?? 10_000
        XCTAssertLessThan(scanMs, 250, "lean structural scan exceeded its 250 ms regression budget")
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 30)
        controller.window.close()
    }

    func testActivityVirtualizationParksOlderCardsButKeepsRailIndex() async throws {
        let controller = BrowserWindowController()
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticToolHeavyConversation(activityCount: 30), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 900_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual((snapshot["activityTotal"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((snapshot["hiddenActivities"] as? NSNumber)?.intValue, 18)
        XCTAssertEqual(snapshot["activityMode"] as? String, "compact")
        let railRows = try await Self.evaluate("document.querySelectorAll('#chatgpt-stable-activity-list button').length", in: controller.webView) as? NSNumber
        XCTAssertEqual(railRows?.intValue, 30)
        controller.window.close()
    }

    func testStreamingActivityVirtualizationKeepsLatestSix() async throws {
        let controller = BrowserWindowController()
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
        controller.show(loadHome: false)
        controller.webView.loadHTMLString(Self.syntheticActionFixture(), baseURL: URL(string: "https://chatgpt.com/c/test")!)
        try await Task.sleep(nanoseconds: 700_000_000)
        let opacity = try await Self.evaluate("getComputedStyle(document.querySelector('[data-testid=copy-turn-action-button]')).opacity", in: controller.webView) as? String
        XCTAssertEqual(opacity, "0.08")
        controller.window.close()
    }



    func testLeanInterfaceHidesOnlyNonConversationUpsellChrome() async throws {
        let controller = BrowserWindowController()
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


    private static func syntheticNoisyConversation(noiseNodes: Int, activityCount: Int) -> String {
        let noise = String(repeating: "<span class='noise'></span>", count: noiseNodes)
        let tools = (0..<activityCount).map { index in
            "<details data-testid='tool-search-\(index)'><summary>tool</summary><div>x</div></details>"
        }.joined()
        return """
        <html><body>\(noise)<div id='scroll' style='height:300px;overflow-y:auto'><section data-turn-id='t0' data-testid='conversation-turn-0'><div data-message-author-role='assistant'>\(tools)</div></section></div></body></html>
        """
    }

    private static func syntheticToolHeavyConversation(activityCount: Int, generating: Bool = false) -> String {
        let tools = (0..<activityCount).map { index in
            "<details data-testid='tool-search-\(index)'><summary>tool</summary><div>x</div></details>"
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
              <pre><code>x</code></pre><table><tr><td>x</td></tr></table><figure><img alt='x' src='data:image/gif;base64,R0lGODlhAQABAAAAACw='></figure>
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
