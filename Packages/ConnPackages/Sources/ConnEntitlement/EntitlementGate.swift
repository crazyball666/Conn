/// Features that can be gated by the Conn Pro subscription.
public enum EntitlementFeature: String, CaseIterable, Hashable, Sendable {
    case terminal
    case processControl
    case logCenter
    case singleHostExecution
    case fileManagement
    case dockerManagement
    case batchExecution
}

/// The only subscription levels understood by the feature layer.
public enum EntitlementSnapshot: Equatable, Sendable {
    case free
    case pro
}

/// Pure, deterministic entitlement policy shared by the App and tests.
public struct EntitlementGate: Equatable, Sendable {
    public static let freeHostLimit = 2

    public let snapshot: EntitlementSnapshot

    public init(snapshot: EntitlementSnapshot) {
        self.snapshot = snapshot
    }

    public var isPro: Bool {
        snapshot == .pro
    }

    public func canAddHost(currentCount: Int) -> Bool {
        isPro || currentCount < Self.freeHostLimit
    }

    public func allowed(_ feature: EntitlementFeature) -> Bool {
        switch feature {
        case .terminal, .processControl, .logCenter, .singleHostExecution:
            return true
        case .fileManagement, .dockerManagement, .batchExecution:
            return isPro
        }
    }
}
