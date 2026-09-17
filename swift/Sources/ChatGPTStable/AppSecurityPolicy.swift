import Foundation

/// Deliberately small navigation policy for the native shell.
/// No native data bridge exists, so web content cannot request cookies, files, clipboard data,
/// local drafts, or other application-side secrets.
enum AppSecurityPolicy {
    static let homeURL = URL(string: "https://chatgpt.com/")!

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

    static func isMediaCaptureHost(_ host: String) -> Bool {
        host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            || host == "chat.openai.com" || host.hasSuffix(".chat.openai.com")
    }

    private static func matches(_ host: String, against set: Set<String>) -> Bool {
        set.contains(host) || set.contains(where: { host.hasSuffix("." + $0) })
    }
}
