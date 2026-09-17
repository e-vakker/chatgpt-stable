import WebKit
import XCTest
@testable import ChatGPTStable

@MainActor
final class WarmConversationCacheTests: XCTestCase {
    func testLRUEvictionKeepsActiveAndProtectedViews() {
        let cache = WarmConversationCache(maxEntries: 2)
        let a = WKWebView()
        let b = WKWebView()
        let c = WKWebView()

        cache.store(a, for: "/c/a", protected: true)
        cache.store(b, for: "/c/b", protected: false)
        cache.store(c, for: "/c/c", protected: false)

        let evicted = cache.evictIfNeeded(excluding: "/c/c")
        XCTAssertEqual(evicted.count, 1)
        XCTAssertTrue(evicted.first === b)
        XCTAssertEqual(cache.stats().count, 2)
        XCTAssertTrue(cache.contains(a))
        XCTAssertTrue(cache.contains(c))
    }

    func testCriticalEvictionCanDropProtectedInactiveView() {
        let cache = WarmConversationCache(maxEntries: 2)
        let active = WKWebView()
        let protected = WKWebView()

        cache.store(active, for: "/c/active", protected: false)
        cache.store(protected, for: "/c/protected", protected: true)

        XCTAssertTrue(cache.evictInactive(excluding: active).isEmpty)
        let evicted = cache.evictInactive(excluding: active, includeProtected: true)
        XCTAssertEqual(evicted.count, 1)
        XCTAssertTrue(evicted.first === protected)
        XCTAssertEqual(cache.stats().count, 1)
    }
}
