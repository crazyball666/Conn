import ConnKit
import Foundation

/// 远端脚本共享调用与转义规则的语言家族。
public enum RemoteScriptFamily: String, Sendable, Hashable {
    case posix
    /// Windows 远端命令的扩展键；本轮不注册执行 provider。
    case powershell
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
    case invalidResolvedExecutablePath
}

/// A machine-protocol runtime pinned to an interpreter path that was already probed.
public struct PreparedRemoteScriptRuntime: Sendable, Equatable {
    public let family: RemoteScriptFamily
    public let interpreter: ShellInterpreter
    public let resolvedExecutablePath: String

    init(
        family: RemoteScriptFamily,
        interpreter: ShellInterpreter,
        resolvedExecutablePath: String
    ) {
        self.family = family
        self.interpreter = interpreter
        self.resolvedExecutablePath = resolvedExecutablePath
    }

    public func invocation(for script: String) throws -> String {
        "\(POSIXShellArgument.encode(resolvedExecutablePath)) -c \(POSIXShellArgument.encode(script))"
    }
}

/// Linux 和 macOS 上的 POSIX Shell 脚本执行器。
public struct POSIXScriptExecutionProvider: RemoteScriptExecutionProvider {
    public static let supportedInterpreterWhitelist: Set<ShellInterpreter> = [.sh, .bash, .zsh]

    public let family = RemoteScriptFamily.posix
    public let supportedPlatforms: Set<RemotePlatformKind> = [.linux, .macOS]
    public let supportedInterpreters: Set<ShellInterpreter>

    public init(
        supportedInterpreters: Set<ShellInterpreter> = POSIXScriptExecutionProvider
            .supportedInterpreterWhitelist
    ) {
        self.supportedInterpreters = supportedInterpreters.intersection(
            POSIXScriptExecutionProvider.supportedInterpreterWhitelist
        )
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

        return "\(POSIXShellArgument.encode(interpreter.rawValue)) -c \(POSIXShellArgument.encode(script))"
    }

    public func prepareRuntime(
        resolvedExecutablePath: String,
        interpreter: ShellInterpreter
    ) throws -> PreparedRemoteScriptRuntime {
        guard supportedInterpreters.contains(interpreter) else {
            throw RemoteScriptExecutionError.unsupportedInterpreter(interpreter)
        }
        guard Self.isValidResolvedExecutablePath(resolvedExecutablePath) else {
            throw RemoteScriptExecutionError.invalidResolvedExecutablePath
        }
        return PreparedRemoteScriptRuntime(
            family: family,
            interpreter: interpreter,
            resolvedExecutablePath: resolvedExecutablePath
        )
    }

    private static func isValidResolvedExecutablePath(_ path: String) -> Bool {
        guard path.first == "/" else { return false }
        return !path.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
        }
    }
}

private enum POSIXShellArgument {
    private static let safeScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
    )

    static func encode(_ value: String) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ safeScalars.contains($0) })
        else {
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return value
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
