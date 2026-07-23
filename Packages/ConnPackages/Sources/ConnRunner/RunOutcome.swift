import Foundation

/// 一次静默执行的结果（结果卡展示 stdout / exit code，方案 §4.6）。
public struct RunOutcome: Sendable, Equatable {
    /// 实际执行的最终命令（变量已填充）。
    public let command: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var isSuccess: Bool { exitCode == 0 }

    public init(command: String, exitCode: Int32, stdout: String, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
