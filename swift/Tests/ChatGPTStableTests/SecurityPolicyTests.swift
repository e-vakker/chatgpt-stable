import XCTest
@testable import ChatGPTStable

final class SecurityPolicyTests: XCTestCase {
    func testTrustedChatGPTAndAuthHosts() {
        XCTAssertTrue(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "https://chatgpt.com/")!))
        XCTAssertTrue(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "https://auth.openai.com/")!))
        XCTAssertTrue(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "https://accounts.google.com/")!))
    }

    func testRejectsLookalikesAndUnsafeSchemes() {
        XCTAssertFalse(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "https://chatgpt.com.evil.example/")!))
        XCTAssertFalse(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "http://chatgpt.com/")!))
        XCTAssertFalse(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "https://user:pass@chatgpt.com/")!))
        XCTAssertFalse(AppSecurityPolicy.isTrustedMainFrameURL(URL(string: "file:///etc/passwd")!))
    }

    func testExternalURLsRequireHTTPSAndStripAuthSecrets() {
        let ordinary = AppSecurityPolicy.safeExternalURL(URL(string: "https://example.com/article?q=1#fragment")!)
        XCTAssertEqual(ordinary?.query, "q=1")
        XCTAssertNil(ordinary?.fragment)
        let auth = AppSecurityPolicy.safeExternalURL(URL(string: "https://auth.openai.com/callback?code=secret#token")!)
        XCTAssertNil(auth?.query)
        XCTAssertNil(auth?.fragment)
        XCTAssertNil(AppSecurityPolicy.safeExternalURL(URL(string: "http://example.com/")!))
        XCTAssertNil(AppSecurityPolicy.safeExternalURL(URL(string: "https://user:pass@example.com/")!))
    }

    func testSubframesCannotUseLocalOrScriptSchemes() {
        let source = URL(string: "https://chatgpt.com/")!
        XCTAssertTrue(AppSecurityPolicy.isSafeSubframeURL(URL(string: "https://challenges.cloudflare.com/")!, sourceURL: source))
        XCTAssertTrue(AppSecurityPolicy.isSafeSubframeURL(URL(string: "about:blank")!, sourceURL: source))
        XCTAssertFalse(AppSecurityPolicy.isSafeSubframeURL(URL(string: "javascript:alert(1)")!, sourceURL: source))
        XCTAssertFalse(AppSecurityPolicy.isSafeSubframeURL(URL(string: "file:///tmp/x")!, sourceURL: source))
    }

    func testMediaCaptureIsLimitedToChatSurfaces() {
        XCTAssertTrue(AppSecurityPolicy.isMediaCaptureHost("chatgpt.com"))
        XCTAssertTrue(AppSecurityPolicy.isMediaCaptureHost("chat.openai.com"))
        XCTAssertFalse(AppSecurityPolicy.isMediaCaptureHost("auth.openai.com"))
        XCTAssertFalse(AppSecurityPolicy.isMediaCaptureHost("accounts.google.com"))
    }
}
