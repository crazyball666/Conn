import Foundation

/// 一条执行审计记录（方案 §4.4/§4.6：容器启停、片段执行等写操作入 run_history）。
///
/// 只记本地、永不上传（红线 §2）。`outputHead` 只留输出头部，避免存整段日志。
public struct RunHistoryEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let hostUUID: String
    public let command: String
    /// 退出码。nil 表示流式/未捕获退出码的操作。
    public let exitCode: Int32?
    /// 输出头部（截断）。
    public let outputHead: String?
    public let ranAt: Int64

    public init(
        id: String = UUID().uuidString,
        hostUUID: String,
        command: String,
        exitCode: Int32? = nil,
        outputHead: String? = nil,
        ranAt: Int64 = Timestamp.now()
    ) {
        self.id = id
        self.hostUUID = hostUUID
        self.command = command
        self.exitCode = exitCode
        self.outputHead = outputHead
        self.ranAt = ranAt
    }

    public var isSuccess: Bool { (exitCode ?? 0) == 0 }
}
