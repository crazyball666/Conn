import ConnSSH
import Foundation

public enum TmuxOperationError: Error, Sendable, Equatable {
    case invalidName
    case invalidClientTarget
    case invalidProfileID
}

/// A name Conn is allowed to create or rename. Existing remote names are decoded separately
/// and may be displayed even when they do not satisfy these authoring constraints.
public struct TmuxName: Sendable, Codable, Equatable, Hashable {
    public static let maximumUTF8Length = 256

    public let value: String

    public init(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty,
              value.utf8.count <= Self.maximumUTF8Length,
              !Self.containsControlCharacter(value)
        else {
            throw TmuxOperationError.invalidName
        }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
        }
    }
}

/// A target-client name obtained from a verified `list-clients` snapshot.
public struct TmuxClientTarget: Sendable, Equatable, Hashable {
    public static let maximumUTF8Length = 1024

    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= Self.maximumUTF8Length,
              !value.unicodeScalars.contains(where: { scalar in
                  scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
              })
        else {
            throw TmuxOperationError.invalidClientTarget
        }
        self.value = value
    }
}

public enum TmuxSplitOrientation: String, Sendable, Codable, Equatable {
    /// Creates left/right panes (`split-window -h`).
    case horizontal
    /// Creates top/bottom panes (`split-window -v`).
    case vertical
}

/// Closed AST for operations against an already identified tmux server instance.
///
/// Executors must wrap these in a request carrying the expected server token and control
/// generation. Raw tmux commands are deliberately not representable.
public enum TmuxOperation: Sendable, Equatable {
    case createSession(name: TmuxName?)
    case renameSession(TmuxSessionID, to: TmuxName)
    case detachClient(TmuxClientTarget)
    case killSession(TmuxSessionID)

    case selectWindow(TmuxWindowID, for: TmuxClientTarget)
    case createWindow(in: TmuxSessionID, name: TmuxName?)
    case renameWindow(TmuxWindowID, to: TmuxName)
    case killWindow(TmuxWindowID)

    case selectPane(TmuxPaneID, for: TmuxClientTarget)
    case splitPane(TmuxPaneID, orientation: TmuxSplitOrientation)
    case setPaneZoom(TmuxPaneID, zoomed: Bool)
    case killPane(TmuxPaneID)
}

/// The only operation allowed to create a workspace without an existing instance token.
/// Its executor additionally requires a short-lived, one-shot server-absent claim.
public enum TmuxBootstrapOperation: Sendable, Equatable {
    case createSession(name: TmuxName?)
}

/// Execution semantics are explicit so transport/executor code never infers retry safety from
/// a rendered command string. Mutations are never retried after they may have been dispatched,
/// even when applying the intended state twice would otherwise be idempotent.
public enum TmuxOperationSemantics: String, Sendable, Codable, Equatable, CaseIterable {
    case readOnly
    case idempotentMutation
    case nonIdempotentMutation
    case destructive
}

public extension TmuxOperation {
    var semantics: TmuxOperationSemantics {
        switch self {
        case .renameSession, .detachClient, .selectWindow, .renameWindow, .selectPane,
             .setPaneZoom:
            .idempotentMutation
        case .createSession, .createWindow, .splitPane:
            .nonIdempotentMutation
        case .killSession, .killWindow, .killPane:
            .destructive
        }
    }

    var isMutation: Bool {
        semantics != .readOnly
    }

    var isDestructive: Bool {
        semantics == .destructive
    }

    /// A read-only query may be replayed after an uncertain dispatch. No current
    /// `TmuxOperation` is read-only; snapshot queries use their own typed query layer.
    var allowsAutomaticRetryAfterPossibleDispatch: Bool {
        semantics == .readOnly
    }
}

/// Complete runtime identity for one operation queue. Equal tmux socket/PID values on another
/// host or backend profile are deliberately a different scope.
public struct TmuxOperationScope: Sendable, Equatable, Hashable {
    public static let maximumProfileIDUTF8Length = 256

    public let connectionIdentity: SSHConnectionIdentity
    public let profileID: String
    public let instanceToken: TmuxServerInstanceToken
    public let generation: UInt64

    public init(
        connectionIdentity: SSHConnectionIdentity,
        profileID: String,
        instanceToken: TmuxServerInstanceToken,
        generation: UInt64
    ) throws {
        guard !profileID.isEmpty,
              profileID.utf8.count <= Self.maximumProfileIDUTF8Length,
              !profileID.unicodeScalars.contains(where: { scalar in
                  scalar.value <= 0x1F || (0x7F ... 0x9F).contains(scalar.value)
              })
        else {
            throw TmuxOperationError.invalidProfileID
        }

        self.connectionIdentity = connectionIdentity
        self.profileID = profileID
        self.instanceToken = instanceToken
        self.generation = generation
    }
}

/// Transport-neutral request. The future executor chooses Control Mode or a guarded one-shot
/// invocation without changing this operation or its runtime scope.
public struct TmuxOperationRequest: Sendable, Equatable {
    public let scope: TmuxOperationScope
    public let operation: TmuxOperation

    public init(scope: TmuxOperationScope, operation: TmuxOperation) {
        self.scope = scope
        self.operation = operation
    }
}
