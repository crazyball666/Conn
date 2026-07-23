import Foundation

/// 远端一个进程的快照（进程视角 P0，PRD §5.4）。
///
/// 命名为 `RemoteProcess` 而非 `Process`，避免与 Foundation.Process 冲突。
public struct RemoteProcess: Identifiable, Sendable, Equatable {
    public let pid: Int32
    /// 命令名（`comm`，不含参数）。
    public let command: String
    /// CPU 占用百分比 0–100。
    public let cpu: Double
    /// 内存占用百分比 0–100。
    public let mem: Double

    public var id: Int32 { pid }

    public init(pid: Int32, command: String, cpu: Double, mem: Double) {
        self.pid = pid
        self.command = command
        self.cpu = cpu
        self.mem = mem
    }
}
