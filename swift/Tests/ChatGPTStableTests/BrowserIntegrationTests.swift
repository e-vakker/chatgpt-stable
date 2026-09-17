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
}
