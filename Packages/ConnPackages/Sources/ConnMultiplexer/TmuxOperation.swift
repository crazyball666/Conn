import Foundation

public enum TmuxOperationError: Error, Sendable, Equatable {
    case invalidName
    case invalidClientTarget
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
