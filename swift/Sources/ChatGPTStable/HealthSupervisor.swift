import Foundation

enum BrowserHealthState: String {
    case starting, loading, healthy, degraded
    case waitingForNetwork, recovering, failed
}

enum BrowserFailureKind: String {
    case rendererTerminated
    case blankRender
    case heartbeatTimeout
    case navigationFailed
    case navigationStalled
    case networkRestored
}

enum RecoveryAction: String, Equatable {
    case none
    case softReload
    case hardReload
    case rebuildWebView
    case pauseForNetwork
    case requireManual
}

struct BrowserHealthSnapshot {
    let state: BrowserHealthState
    let isOnline: Bool
    let totalRecoveries: Int
    let recentRecoveries: Int
    let consecutiveHeartbeatTimeouts: Int
    let lastHeartbeatLatency: TimeInterval?
    let lastFailure: BrowserFailureKind?
    let lastAction: RecoveryAction
}

final class HealthSupervisor {
    private let now: () -> Date
    private let recoveryWindow: TimeInterval = 10 * 60
    private let maximumAutomaticRecoveries = 3
    private var recoveryEvents: [Date] = []
    private var pendingNetworkRecovery = false

    private(set) var state: BrowserHealthState = .starting
    private(set) var isOnline = true
    private(set) var totalRecoveries = 0
    private(set) var consecutiveHeartbeatTimeouts = 0
    private(set) var lastHeartbeatLatency: TimeInterval?
    private(set) var lastFailure: BrowserFailureKind?
    private(set) var lastAction: RecoveryAction = .none

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func navigationStarted() {
        state = isOnline ? .loading : .waitingForNetwork
    }

    func navigationFinished() {
        state = .healthy
        consecutiveHeartbeatTimeouts = 0
        pendingNetworkRecovery = false
    }

    func heartbeatSucceeded(latency: TimeInterval, renderable: Bool) -> RecoveryAction {
        lastHeartbeatLatency = latency
        consecutiveHeartbeatTimeouts = 0
        if renderable {
            if state == .degraded || state == .starting {
                state = .healthy
            }
            lastAction = .none
            return .none
        }
        return automaticRecovery(for: .blankRender)
    }

    func heartbeatTimedOut() -> RecoveryAction {
        guard isOnline else {
            pendingNetworkRecovery = true
            state = .waitingForNetwork
            lastAction = .pauseForNetwork
            return .pauseForNetwork
        }

        consecutiveHeartbeatTimeouts += 1
        guard consecutiveHeartbeatTimeouts >= 2 else {
            state = .degraded
            lastFailure = .heartbeatTimeout
            lastAction = .none
            return .none
        }

        consecutiveHeartbeatTimeouts = 0
        return automaticRecovery(for: .heartbeatTimeout)
    }

    func navigationStalled() -> RecoveryAction {
        guard isOnline else {
            pendingNetworkRecovery = true
            state = .waitingForNetwork
            lastAction = .pauseForNetwork
            return .pauseForNetwork
        }
        return automaticRecovery(for: .navigationStalled)
    }

    func navigationFailed() -> RecoveryAction {
        guard isOnline else {
            pendingNetworkRecovery = true
            state = .waitingForNetwork
            lastAction = .pauseForNetwork
            return .pauseForNetwork
        }
        return automaticRecovery(for: .navigationFailed)
    }

    func rendererTerminated() -> RecoveryAction {
        automaticRecovery(for: .rendererTerminated)
    }

    func networkChanged(isOnline: Bool) -> RecoveryAction {
        let wasOnline = self.isOnline
        self.isOnline = isOnline

        guard isOnline else {
            pendingNetworkRecovery = true
            state = .waitingForNetwork
            lastAction = .pauseForNetwork
            return .pauseForNetwork
        }

        guard !wasOnline, pendingNetworkRecovery else {
            return .none
        }
        pendingNetworkRecovery = false
        return automaticRecovery(for: .networkRestored, minimumLevel: 1)
    }

    func manualRecoveryRequested() -> RecoveryAction {
        recoveryEvents.removeAll()
        consecutiveHeartbeatTimeouts = 0
        state = .recovering
        lastAction = .rebuildWebView
        return .rebuildWebView
    }

    func snapshot() -> BrowserHealthSnapshot {
        purgeOldRecoveries()
        return BrowserHealthSnapshot(
            state: state,
            isOnline: isOnline,
            totalRecoveries: totalRecoveries,
            recentRecoveries: recoveryEvents.count,
            consecutiveHeartbeatTimeouts: consecutiveHeartbeatTimeouts,
            lastHeartbeatLatency: lastHeartbeatLatency,
            lastFailure: lastFailure,
            lastAction: lastAction
        )
    }

    private func automaticRecovery(
        for failure: BrowserFailureKind,
        minimumLevel: Int = 0
    ) -> RecoveryAction {
        purgeOldRecoveries()
        lastFailure = failure

        guard recoveryEvents.count < maximumAutomaticRecoveries else {
            state = .failed
            lastAction = .requireManual
            return .requireManual
        }
        let level = max(minimumLevel, recoveryEvents.count)
        let action: RecoveryAction
        switch failure {
        case .rendererTerminated:
            action = level == 0 ? .hardReload : .rebuildWebView
        case .navigationFailed, .networkRestored:
            action = level <= 1 ? .hardReload : .rebuildWebView
        case .blankRender, .heartbeatTimeout, .navigationStalled:
            switch level {
            case 0: action = .softReload
            case 1: action = .hardReload
            default: action = .rebuildWebView
            }
        }

        recoveryEvents.append(now())
        totalRecoveries += 1
        state = .recovering
        lastAction = action
        return action
    }

    private func purgeOldRecoveries() {
        let cutoff = now().addingTimeInterval(-recoveryWindow)
        recoveryEvents.removeAll { $0 < cutoff }
    }
}
