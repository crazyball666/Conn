import Foundation

/// An SSH terminal mode opcode. Raw values follow RFC 4254 so transports can preserve
/// modes added after this library version without expanding a closed enum.
public struct RemoteTerminalMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let interruptCharacter = Self(rawValue: 1)
    public static let quitCharacter = Self(rawValue: 2)
    public static let eraseCharacter = Self(rawValue: 3)
    public static let killCharacter = Self(rawValue: 4)
    public static let endOfFileCharacter = Self(rawValue: 5)
    public static let signalCharacters = Self(rawValue: 50)
    public static let canonicalInput = Self(rawValue: 51)
    public static let echo = Self(rawValue: 53)
    public static let outputPostProcessing = Self(rawValue: 70)
    public static let inputSpeed = Self(rawValue: 128)
    public static let outputSpeed = Self(rawValue: 129)
}

public struct RemoteTerminalRequest: Sendable, Equatable {
    public let type: String
    public let size: TermSize
    public let modes: [RemoteTerminalMode: UInt32]

    public init(
        type: String,
        size: TermSize,
        modes: [RemoteTerminalMode: UInt32] = [:]
    ) {
        self.type = type
        self.size = size
        self.modes = modes
    }
}

/// Requests an SSH exec channel, optionally preceded by a PTY allocation request.
public struct RemoteProcessRequest: Sendable, Equatable {
    public let command: String
    public let terminal: RemoteTerminalRequest?

    public init(command: String, terminal: RemoteTerminalRequest? = nil) {
        self.command = command
        self.terminal = terminal
    }
}

public enum RemoteProcessOutput: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

public struct RemoteProcessExit: Sendable, Equatable {
    public let exitCode: Int32?
    public let signal: String?

    public init(exitCode: Int32?, signal: String?) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

public enum RemoteProcessError: Error, Sendable, Equatable {
    /// The transport has not implemented bidirectional exec channels.
    case unsupported
    /// The configured bounded bridge could not accept another output chunk.
    case outputBufferOverflow(maxBufferedChunks: Int)
    /// Resize was requested for a process that did not allocate a PTY.
    case terminalNotAllocated
    /// SSH opcode zero is reserved for the terminal-mode end marker.
    case invalidTerminalMode(UInt8)
}

public protocol RemoteProcessChannel: AnyObject, Sendable {
    var output: AsyncThrowingStream<RemoteProcessOutput, Error> { get }
    func write(_ data: Data) async throws
    func resize(_ size: TermSize) async throws
    func result() async throws -> RemoteProcessExit
    func close() async
}
