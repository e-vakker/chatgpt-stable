import Foundation

enum SessionCheckpoint {
    private static let defaultsKey = "ChatGPTStable.LastTrustedPage"

    static func load(defaults: UserDefaults = .standard) -> URL? {
        guard let raw = defaults.string(forKey: defaultsKey),
              let url = URL(string: raw),
              let safe = AppSecurityPolicy.checkpointURL(url) else {
            return nil
        }
        return safe
    }

    static func save(_ url: URL, defaults: UserDefaults = .standard) {
        guard let safe = AppSecurityPolicy.checkpointURL(url) else { return }
        defaults.set(safe.absoluteString, forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
