import WebKit

@MainActor
final class WarmConversationCache {
    struct Stats {
        let count: Int
        let hits: Int
        let misses: Int
    }

    private struct Entry {
        let view: WKWebView
        var stamp: UInt64
        var protected: Bool
    }

    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var hits = 0
    private var misses = 0

    init(maxEntries: Int = 2) {
        self.maxEntries = max(1, maxEntries)
    }
    func view(for key: String) -> WKWebView? {
        guard var entry = entries[key] else {
            misses += 1
            return nil
        }
        hits += 1
        clock &+= 1
        entry.stamp = clock
        entries[key] = entry
        return entry.view
    }

    func store(_ view: WKWebView, for key: String, protected: Bool) {
        entries = entries.filter { $0.key == key || $0.value.view !== view }
        clock &+= 1
        entries[key] = Entry(view: view, stamp: clock, protected: protected)
    }

    func setProtected(_ protected: Bool, for key: String) {
        guard var entry = entries[key] else { return }
        entry.protected = protected
        entries[key] = entry
    }

    func remove(view: WKWebView) {
        entries = entries.filter { $0.value.view !== view }
    }
    func evictIfNeeded(excluding activeKey: String?) -> [WKWebView] {
        var evicted: [WKWebView] = []
        while entries.count > maxEntries {
            guard let candidate = entries
                .filter({ $0.key != activeKey && !$0.value.protected })
                .min(by: { $0.value.stamp < $1.value.stamp }) else { break }
            entries.removeValue(forKey: candidate.key)
            evicted.append(candidate.value.view)
        }
        return evicted
    }

    func evictInactive(excluding activeView: WKWebView?) -> [WKWebView] {
        let keys = entries.compactMap { key, entry -> String? in
            guard !entry.protected, entry.view !== activeView else { return nil }
            return key
        }
        return keys.compactMap { key in
            entries.removeValue(forKey: key)?.view
        }
    }

    func drain() -> [WKWebView] {
        let views = entries.values.map(\.view)
        entries.removeAll()
        return views
    }

    func stats() -> Stats {
        Stats(count: entries.count, hits: hits, misses: misses)
    }

    func contains(_ view: WKWebView) -> Bool {
        entries.values.contains { $0.view === view }
    }

    func containsKey(_ key: String) -> Bool {
        entries[key] != nil
    }
}
