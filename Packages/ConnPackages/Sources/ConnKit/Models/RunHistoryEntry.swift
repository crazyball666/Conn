import Foundation

/// 审计记录的可知性。远端命令可能在本地断连或超时后仍继续执行，不能把这种情况
/// 误呈现为成功或失败；`pending` 仅用于正在等待流式命令终态的短暂窗口。
public enum RunHistoryState: String, Sendable, Equatable, Codable {
    case pending
    case known
    case unknown
}

/// 一条脚本执行审计记录（方案 §4.4/§4.6：容器启停、片段执行等写操作入 run_history）。
///
/// 只记本地、永不上传（红线 §2）。`outputHead` 只留输出头部，避免存整段日志。
public struct RunHistoryEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let hostUUID: String
    public let script: String
    public let interpreter: ShellInterpreter
    /// 退出码。nil 表示流式/未捕获退出码的操作。
    public let exitCode: Int32?
    /// 输出头部（截断）。
    public let outputHead: String?
    /// 结果是否已从远端拿到最终退出码。
    public let state: RunHistoryState
    public let ranAt: Int64

    public init(
        id: String = UUID().uuidString,
        hostUUID: String,
        script: String,
        interpreter: ShellInterpreter = .sh,
        exitCode: Int32? = nil,
        outputHead: String? = nil,
        state: RunHistoryState = .known,
        ranAt: Int64 = Timestamp.now()
    ) {
        self.id = id
        self.hostUUID = hostUUID
        self.script = script
        self.interpreter = interpreter
        self.exitCode = exitCode
        self.outputHead = outputHead
        self.state = state
        self.ranAt = ranAt
    }

    /// 只有明确收到了退出码 0 才是成功。历史版本的 nil 退出码及传输中断都不能
    /// 乐观地显示为成功。
    public var isSuccess: Bool { state == .known && exitCode == 0 }
}
