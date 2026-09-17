import Foundation
import XCTest
@testable import ChatGPTStable

final class HealthSupervisorTests: XCTestCase {
    func testHeartbeatNeedsTwoConsecutiveTimeoutsBeforeRecovery() {
        let supervisor = HealthSupervisor()
        XCTAssertEqual(supervisor.heartbeatTimedOut(), .none)
        XCTAssertEqual(supervisor.snapshot().state, .degraded)
        XCTAssertEqual(supervisor.heartbeatTimedOut(), .softReload)
        XCTAssertEqual(supervisor.snapshot().state, .recovering)
    }

    func testRecoveryEscalatesWithoutLoopingForever() {
        let supervisor = HealthSupervisor()
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.01, renderable: false), .softReload)
        supervisor.navigationFinished()
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.01, renderable: false), .hardReload)
        supervisor.navigationFinished()
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.01, renderable: false), .rebuildWebView)
        supervisor.navigationFinished()
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.01, renderable: false), .requireManual)
        XCTAssertEqual(supervisor.snapshot().state, .failed)
    }

    func testRendererTerminationSkipsWeakestRecovery() {
        let supervisor = HealthSupervisor()
        XCTAssertEqual(supervisor.rendererTerminated(), .hardReload)
        supervisor.navigationFinished()
        XCTAssertEqual(supervisor.rendererTerminated(), .rebuildWebView)
    }

    func testNetworkLossPausesAndRestoreRecovers() {
        let supervisor = HealthSupervisor()
        XCTAssertEqual(supervisor.networkChanged(isOnline: false), .pauseForNetwork)
        XCTAssertEqual(supervisor.snapshot().state, .waitingForNetwork)
        XCTAssertEqual(supervisor.networkChanged(isOnline: true), .hardReload)
        XCTAssertTrue(supervisor.snapshot().isOnline)
    }

    func testHealthyHeartbeatClearsDegradedState() {
        let supervisor = HealthSupervisor()
        XCTAssertEqual(supervisor.heartbeatTimedOut(), .none)
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.02, renderable: true), .none)
        XCTAssertEqual(supervisor.snapshot().state, .healthy)
        XCTAssertEqual(supervisor.snapshot().consecutiveHeartbeatTimeouts, 0)
    }

    func testRecoveryWindowExpires() {
        var time = Date(timeIntervalSince1970: 1_000)
        let supervisor = HealthSupervisor(now: { time })
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.01, renderable: false), .softReload)
        time = time.addingTimeInterval(601)
        supervisor.navigationFinished()
        XCTAssertEqual(supervisor.heartbeatSucceeded(latency: 0.01, renderable: false), .softReload)
        XCTAssertEqual(supervisor.snapshot().recentRecoveries, 1)
    }

    func testManualRecoveryResetsCircuitBreakerAndRebuilds() {
        let supervisor = HealthSupervisor()
        _ = supervisor.heartbeatSucceeded(latency: 0.01, renderable: false)
        _ = supervisor.heartbeatSucceeded(latency: 0.01, renderable: false)
        XCTAssertEqual(supervisor.manualRecoveryRequested(), .rebuildWebView)
        XCTAssertEqual(supervisor.snapshot().recentRecoveries, 0)
    }
}
