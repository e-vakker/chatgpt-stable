import Foundation

enum PerformancePressureLevel: String {
    case normal, elevated, severe
}

enum PerformancePressureAction: Equatable {
    case none
    case deferred
    case refreshNow
}

struct PerformancePressureSample {
    let domNodes: Int
    let mountedRoles: Int
    let heartbeatLatency: TimeInterval
    let optimizerScanLatency: TimeInterval
    let isGenerating: Bool
    let composerFocused: Bool
    let nearBottom: Bool
}

struct PerformancePressureSnapshot {
    let level: PerformancePressureLevel
    let pendingRefresh: Bool
    let automaticRefreshes: Int
    let severeMeasurements: Int
    let lastRefreshAt: Date?
}

final class PerformancePressureController {
    private let now: () -> Date
    private let cooldown: TimeInterval = 10 * 60
    private var severeMeasurements = 0
    private var pendingRefresh = false
    private var automaticRefreshes = 0
    private var lastRefreshAt: Date?
    private var lastLevel: PerformancePressureLevel = .normal

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func observe(_ sample: PerformancePressureSample, structuralMeasurement: Bool) -> PerformancePressureAction {
        let current = now()
        lastLevel = Self.level(for: sample)

        if pendingRefresh {
            guard !sample.isGenerating, !sample.composerFocused, sample.nearBottom else { return .deferred }
            guard cooldownExpired(at: current) else { return .deferred }
            return performRefresh(at: current)
        }

        guard structuralMeasurement else { return .none }
        if lastLevel == .severe {
            severeMeasurements += 1
        } else {
            severeMeasurements = 0
            return .none
        }

        guard severeMeasurements >= 2 else { return .none }
        guard cooldownExpired(at: current) else {
            severeMeasurements = 0
            return .none
        }

        if sample.isGenerating || sample.composerFocused || !sample.nearBottom {
            pendingRefresh = true
            return .deferred
        }
        return performRefresh(at: current)
    }

    func manualRefreshPerformed() {
        pendingRefresh = false
        severeMeasurements = 0
        lastRefreshAt = now()
    }

    func snapshot() -> PerformancePressureSnapshot {
        PerformancePressureSnapshot(
            level: lastLevel,
            pendingRefresh: pendingRefresh,
            automaticRefreshes: automaticRefreshes,
            severeMeasurements: severeMeasurements,
            lastRefreshAt: lastRefreshAt
        )
    }

    static func level(for sample: PerformancePressureSample) -> PerformancePressureLevel {
        if sample.domNodes >= 12_000 || sample.mountedRoles >= 48 || sample.heartbeatLatency >= 0.40 || sample.optimizerScanLatency >= 0.25 {
            return .severe
        }
        if sample.domNodes >= 4_500 || sample.mountedRoles >= 24 || sample.heartbeatLatency >= 0.08 || sample.optimizerScanLatency >= 0.08 {
            return .elevated
        }
        return .normal
    }

    private func cooldownExpired(at date: Date) -> Bool {
        guard let lastRefreshAt else { return true }
        return date.timeIntervalSince(lastRefreshAt) >= cooldown
    }

    private func performRefresh(at date: Date) -> PerformancePressureAction {
        pendingRefresh = false
        severeMeasurements = 0
        automaticRefreshes += 1
        lastRefreshAt = date
        return .refreshNow
    }
}
