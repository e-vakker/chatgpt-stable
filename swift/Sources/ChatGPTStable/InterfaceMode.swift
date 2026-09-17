enum InterfaceMode: String, CaseIterable {
    case standard
    case lean
    case terminal

    var displayName: String {
        switch self {
        case .standard: "Standard Web"
        case .lean: "Lean"
        case .terminal: "Terminal"
        }
    }

    var usesPerformanceLayer: Bool {
        self != .standard
    }

    var isTerminal: Bool {
        self == .terminal
    }
}
