import Foundation

/// 可用于执行脚本的远端 Shell。
///
/// 只保留常见且可预测的解释器，不允许把用户输入直接拼进执行器名称，
/// 避免脚本执行链路出现额外的命令注入面。
public enum ShellInterpreter: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case sh
    case bash
    case zsh

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sh: "POSIX sh"
        case .bash: "Bash"
        case .zsh: "Zsh"
        }
    }

    /// 将脚本包装为解释器的 `-c` 调用。
    ///
    /// 单引号转义采用 POSIX 通用写法，换行、变量和 Shell 特殊字符都会作为
    /// 同一个脚本文本传给解释器，而不是被外层 SSH 命令拆成多条命令。
    public func invocation(for script: String) -> String {
        "\(rawValue) -c '\(script.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
