import Foundation

/// Deliberately small navigation policy for the native shell.
/// The only page-to-native bridge is an isolated, reply-only warm-cache query that accepts
/// a sanitized conversation path; it cannot request cookies, files, clipboard data, drafts or secrets.
enum AppSecurityPolicy {
    static let homeURL = URL(string: "https://chatgpt.com/")!
    static let internalConversationScheme = "chatgpt-stable"

    private static let trustedHosts: Set<String> = [
        "chatgpt.com",
        "chat.openai.com",
        "openai.com",
        "auth.openai.com",
        "auth0.openai.com",
        "login.openai.com",
        "sentinel.openai.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
    ]

    private static let authenticationHosts: Set<String> = [
        "auth.openai.com",
        "auth0.openai.com",
        "login.openai.com",
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
    ]

    static func isTrustedMainFrameURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else {
            return false
        }
        return matches(host, against: trustedHosts)
    }

    static func isSafeSubframeURL(_ url: URL, sourceURL: URL?) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.user == nil && url.password == nil
        case "about":
            return url.absoluteString.lowercased() == "about:blank"
        case "blob", "data":
            return sourceURL.map(isTrustedMainFrameURL) ?? false
        default:
            return false
        }
    }

    static func safeExternalURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        if matches(host, against: authenticationHosts) {
            components.query = nil
        }
        return components.url
    }

    static func conversationKey(for url: URL) -> String? {
        guard let safe = checkpointURL(url), isConversationPath(safe.path) else { return nil }
        return safe.path
    }

    static func conversationURL(forPath path: String) -> URL? {
        guard path.hasPrefix("/"), path.count <= 2048,
              !path.contains("\\"), !path.contains(".."),
              !path.lowercased().hasPrefix("/api"),
              !path.lowercased().hasPrefix("/backend"),
              !path.lowercased().hasPrefix("/auth"),
              !path.lowercased().hasPrefix("/login"),
              isConversationPath(path) else { return nil }
        var target = URLComponents()
        target.scheme = "https"
        target.host = "chatgpt.com"
        target.path = path
        return target.url
    }

    static func conversationTarget(fromInternalURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == internalConversationScheme,
              url.host?.lowercased() == "conversation",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
        return conversationURL(forPath: path)
    }

    static func checkpointURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              isMediaCaptureHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let path = components.path.lowercased()
        guard !path.hasPrefix("/auth"), !path.hasPrefix("/login"),
              !path.hasPrefix("/api"), !path.hasPrefix("/backend") else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func isMediaCaptureHost(_ host: String) -> Bool {
        host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            || host == "chat.openai.com" || host.hasSuffix(".chat.openai.com")
    }

    private static func isConversationPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(of: "c"), parts.indices.contains(index + 1) else { return false }
        return !parts[index + 1].isEmpty
    }

    private static func matches(_ host: String, against set: Set<String>) -> Bool {
        set.contains(host) || set.contains(where: { host.hasSuffix("." + $0) })
    }
}
