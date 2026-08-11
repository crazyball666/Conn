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
}
