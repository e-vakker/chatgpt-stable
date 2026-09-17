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

    func testExternalURLsRequireHTTPSAndNoEmbeddedCredentials() {
        XCTAssertNotNil(AppSecurityPolicy.safeExternalURL(URL(string: "https://example.com/article#fragment")!))
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
}
