import ConnKit
import Foundation

/// 远端平台探测失败。成功执行但无法识别的平台不属于错误，而是 `.unknown`。
public enum RemotePlatformDetectionError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            message.isEmpty ? "无法识别远端操作系统" : "无法探测远端操作系统：\(message)"
        }
    }
}

public protocol RemotePlatformDetecting: Sendable {
    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile
}

/// 用短命令探测远端平台事实。动态能力（权限、Docker daemon 等）不在这里缓存。
public struct RemotePlatformDetector: RemotePlatformDetecting {
    enum Sentinel {
        static let uname = "__CONN_UNAME__"
        static let windows = "__CONN_WINDOWS__"
        static let release = "__CONN_RELEASE__"
        static let architecture = "__CONN_ARCH__"
        static let shell = "__CONN_SHELL__"
        static let end = "__CONN_END__"
    }

    public static let posixCommand = [
        "echo \(Sentinel.uname)",
        "uname -s 2>/dev/null",
        "echo \(Sentinel.release)",
        "uname -r 2>/dev/null",
        "echo \(Sentinel.architecture)",
        "uname -m 2>/dev/null",
        "echo \(Sentinel.shell)",
        "printf '%s\\n' \"$SHELL\"",
        "echo \(Sentinel.end)",
    ].joined(separator: "; ")

    public static let windowsCommand = """
    powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference='SilentlyContinue'; \
    Write-Output '\(Sentinel.windows)'; Write-Output ([System.Environment]::OSVersion.VersionString); \
    Write-Output '\(Sentinel.architecture)'; Write-Output $env:PROCESSOR_ARCHITECTURE; \
    Write-Output '\(Sentinel.shell)'; Write-Output 'PowerShell'; Write-Output '\(Sentinel.end)'"
    """

    public init() {}

    public func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        let posix = try await session.exec(Self.posixCommand)
        if posix.isSuccess {
            return Self.parse(posix.stdoutText)
        }

        let windows = try await session.exec(Self.windowsCommand)
        guard windows.isSuccess else {
            let message = windows.stderrText.isEmpty ? posix.stderrText : windows.stderrText
            throw RemotePlatformDetectionError.commandFailed(message)
        }
        return Self.parse(windows.stdoutText)
    }

    static func parse(_ output: String) -> RemotePlatformProfile {
        let sections = splitSections(output)
        let uname = firstLine(sections[Sentinel.uname])
        let windows = firstLine(sections[Sentinel.windows])

        let kind: RemotePlatformKind
        if windows?.localizedCaseInsensitiveContains("windows") == true {
            kind = .windows
        } else if uname?.caseInsensitiveCompare("Darwin") == .orderedSame {
            kind = .macOS
        } else if uname?.caseInsensitiveCompare("Linux") == .orderedSame {
            kind = .linux
        } else if let uname,
                  ["mingw", "msys", "cygwin"].contains(where: {
                      uname.localizedCaseInsensitiveContains($0)
                  }) {
            kind = .windows
        } else {
            kind = .unknown
        }

        return RemotePlatformProfile(
            kind: kind,
            release: kind == .windows ? windows : firstLine(sections[Sentinel.release]),
            architecture: firstLine(sections[Sentinel.architecture]),
            shell: parseShell(firstLine(sections[Sentinel.shell]))
        )
    }

    private static func parseShell(_ value: String?) -> ShellInterpreter? {
        guard let name = value?
            .split(separator: "/")
            .last?
            .lowercased()
        else { return nil }
        return ShellInterpreter(rawValue: name)
    }

    private static func firstLine(_ value: String?) -> String? {
        value?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func splitSections(_ output: String) -> [String: String] {
        let sentinels: Set<String> = [
            Sentinel.uname, Sentinel.windows, Sentinel.release,
            Sentinel.architecture, Sentinel.shell, Sentinel.end,
        ]
        var result: [String: String] = [:]
        var current: String?
        var lines: [String] = []

        func flush() {
            guard let current else { return }
            result[current] = lines.joined(separator: "\n")
        }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if sentinels.contains(trimmed) {
                flush()
                current = trimmed
                lines = []
            } else if current != nil {
                lines.append(line)
            }
        }
        flush()
        return result
    }
}
