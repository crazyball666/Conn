import ConnKit
import Foundation

/// 远端脚本共享调用与转义规则的语言家族。
public enum RemoteScriptFamily: String, Sendable, Hashable {
    case posix
}

/// 为特定远端平台和解释器构造探测及执行命令。
public protocol RemoteScriptExecutionProvider: Sendable {
    var family: RemoteScriptFamily { get }
    var supportedPlatforms: Set<RemotePlatformKind> { get }
    var supportedInterpreters: Set<ShellInterpreter> { get }

    func interpreterProbeCommand(for interpreter: ShellInterpreter) -> String
    func invocation(for script: String, interpreter: ShellInterpreter) throws -> String
}

public enum RemoteScriptExecutionError: Error, Sendable, Equatable {
    case unsupportedInterpreter(ShellInterpreter)
}

/// Linux 和 macOS 上的 POSIX Shell 脚本执行器。
public struct POSIXScriptExecutionProvider: RemoteScriptExecutionProvider {
    public let family = RemoteScriptFamily.posix
    public let supportedPlatforms: Set<RemotePlatformKind> = [.linux, .macOS]
    public let supportedInterpreters: Set<ShellInterpreter>

    public init(
        supportedInterpreters: Set<ShellInterpreter> = Set(ShellInterpreter.allCases)
    ) {
        self.supportedInterpreters = supportedInterpreters
    }

    public func interpreterProbeCommand(for interpreter: ShellInterpreter) -> String {
        "command -v \(interpreter.rawValue)"
    }

    public func invocation(
        for script: String,
        interpreter: ShellInterpreter
    ) throws -> String {
        guard supportedInterpreters.contains(interpreter) else {
            throw RemoteScriptExecutionError.unsupportedInterpreter(interpreter)
        }

        let quotedScript = script.replacingOccurrences(of: "'", with: "'\\''")
        return "\(interpreter.rawValue) -c '\(quotedScript)'"
    }
}

/// 按远端平台与解释器共同选择脚本执行 provider。
public struct RemoteScriptExecutionProviderRegistry: Sendable {
    private let providers: [any RemoteScriptExecutionProvider]

    public init(providers: [any RemoteScriptExecutionProvider]) {
        self.providers = providers
    }

    public static let `default` = RemoteScriptExecutionProviderRegistry(
        providers: [POSIXScriptExecutionProvider()]
    )

    public func provider(
        for platform: RemotePlatformKind,
        interpreter: ShellInterpreter
    ) -> (any RemoteScriptExecutionProvider)? {
        providers.first {
            $0.supportedPlatforms.contains(platform)
                && $0.supportedInterpreters.contains(interpreter)
        }
    }
}
