import XCTest
@testable import ChatGPTStable

final class SessionCheckpointTests: XCTestCase {
    func testCheckpointStripsQueryAndFragment() throws {
        let raw = try XCTUnwrap(URL(string: "https://chatgpt.com/c/example?temporary=secret#fragment"))
        let safe = try XCTUnwrap(AppSecurityPolicy.checkpointURL(raw))
        XCTAssertEqual(safe.absoluteString, "https://chatgpt.com/c/example")
    }

    func testCheckpointRejectsExternalAndAuthPages() {
        XCTAssertNil(AppSecurityPolicy.checkpointURL(URL(string: "https://example.com/c/test")!))
        XCTAssertNil(AppSecurityPolicy.checkpointURL(URL(string: "https://chatgpt.com/auth/callback?code=x")!))
        XCTAssertNil(AppSecurityPolicy.checkpointURL(URL(string: "https://chatgpt.com/backend-api/conversation")!))
    }

    func testCheckpointRoundTripUsesOnlySanitizedURL() throws {
        let suite = "ChatGPTStable.SessionCheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SessionCheckpoint.save(URL(string: "https://chatgpt.com/c/example?token=discard#x")!, defaults: defaults)
        let restored = try XCTUnwrap(SessionCheckpoint.load(defaults: defaults))
        XCTAssertEqual(restored.absoluteString, "https://chatgpt.com/c/example")
    }
}
