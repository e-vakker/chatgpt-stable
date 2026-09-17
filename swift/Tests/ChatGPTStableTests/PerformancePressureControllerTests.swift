import XCTest
@testable import ChatGPTStable

final class PerformancePressureControllerTests: XCTestCase {
    private func sample(
        dom: Int = 2_000,
        roles: Int = 8,
        latency: TimeInterval = 0.01,
        generating: Bool = false,
        focused: Bool = false,
        nearBottom: Bool = true
    ) -> PerformancePressureSample {
        PerformancePressureSample(
            domNodes: dom,
            mountedRoles: roles,
            heartbeatLatency: latency,
            isGenerating: generating,
            composerFocused: focused,
            nearBottom: nearBottom
        )
    }

    func testPressureLevels() {
        XCTAssertEqual(PerformancePressureController.level(for: sample()), .normal)
        XCTAssertEqual(PerformancePressureController.level(for: sample(dom: 9_000)), .elevated)
        XCTAssertEqual(PerformancePressureController.level(for: sample(dom: 18_000)), .severe)
        XCTAssertEqual(PerformancePressureController.level(for: sample(roles: 64)), .severe)
        XCTAssertEqual(PerformancePressureController.level(for: sample(latency: 0.8)), .severe)
    }

    func testTwoSevereMeasurementsTriggerRefresh() {
        let controller = PerformancePressureController()
        XCTAssertEqual(controller.observe(sample(dom: 20_000), structuralMeasurement: true), .none)
        XCTAssertEqual(controller.observe(sample(dom: 20_000), structuralMeasurement: true), .refreshNow)
        XCTAssertEqual(controller.snapshot().automaticRefreshes, 1)
    }

    func testGenerationDefersRefreshUntilStreamingStops() {
        let controller = PerformancePressureController()
        let busy = sample(dom: 20_000, generating: true)
        XCTAssertEqual(controller.observe(busy, structuralMeasurement: true), .none)
        XCTAssertEqual(controller.observe(busy, structuralMeasurement: true), .deferred)
        XCTAssertTrue(controller.snapshot().pendingRefresh)

        XCTAssertEqual(controller.observe(sample(dom: 20_000), structuralMeasurement: false), .refreshNow)
        XCTAssertFalse(controller.snapshot().pendingRefresh)
    }

    func testComposerFocusAlsoDefersRefresh() {
        let controller = PerformancePressureController()
        let focused = sample(dom: 20_000, focused: true)
        XCTAssertEqual(controller.observe(focused, structuralMeasurement: true), .none)
        XCTAssertEqual(controller.observe(focused, structuralMeasurement: true), .deferred)
        XCTAssertEqual(controller.observe(sample(dom: 20_000), structuralMeasurement: false), .refreshNow)
    }

    func testReadingEarlierHistoryDefersRefreshUntilBackAtBottom() {
        let controller = PerformancePressureController()
        let readingHistory = sample(dom: 20_000, nearBottom: false)
        XCTAssertEqual(controller.observe(readingHistory, structuralMeasurement: true), .none)
        XCTAssertEqual(controller.observe(readingHistory, structuralMeasurement: true), .deferred)
        XCTAssertTrue(controller.snapshot().pendingRefresh)
        XCTAssertEqual(controller.observe(sample(dom: 20_000), structuralMeasurement: false), .refreshNow)
    }

    func testCooldownPreventsRefreshLoop() {
        var date = Date(timeIntervalSince1970: 1_000)
        let controller = PerformancePressureController(now: { date })
        let severe = sample(dom: 20_000)

        _ = controller.observe(severe, structuralMeasurement: true)
        XCTAssertEqual(controller.observe(severe, structuralMeasurement: true), .refreshNow)

        _ = controller.observe(severe, structuralMeasurement: true)
        XCTAssertEqual(controller.observe(severe, structuralMeasurement: true), .none)
        XCTAssertEqual(controller.snapshot().automaticRefreshes, 1)

        date = date.addingTimeInterval(601)
        _ = controller.observe(severe, structuralMeasurement: true)
        XCTAssertEqual(controller.observe(severe, structuralMeasurement: true), .refreshNow)
        XCTAssertEqual(controller.snapshot().automaticRefreshes, 2)
    }
}
