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
        try await Self.evaluate("window.__chatgptStablePerf?.pressure?.(10000)", in: controller.webView)
        try await Task.sleep(nanoseconds: 400_000_000)

        let snapshot = try await Self.performanceSnapshot(from: controller.webView)
        XCTAssertEqual(snapshot["mode"] as? String, "streaming")
        XCTAssertEqual((snapshot["hidden"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((snapshot["visibleRoles"] as? NSNumber)?.intValue, 4)
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

    private static func evaluate(_ script: String, in webView: WKWebView) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
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
