import Foundation

/// 远端一个进程的快照（进程视角 P0，PRD §5.4）。
///
/// 命名为 `RemoteProcess` 而非 `Process`，避免与 Foundation.Process 冲突。
/// 除 CPU/内存占比外，额外采集运维常看字段：属主、常驻内存、线程数、状态、
/// 运行时长、父进程与完整命令行——GNU `ps` 一次读齐，BusyBox 回退时部分为 nil。
public struct RemoteProcess: Identifiable, Sendable, Equatable {
    public let pid: Int32
    /// 父进程 PID（`ppid`）。
    public let ppid: Int32?
    /// 属主用户（`user`）。
    public let user: String?
    /// 命令短名（用于列表主标题，取自完整命令行首段的 basename）。
    public let command: String
    /// 完整命令行（`args`，含参数，供详情页）。
    public let fullCommand: String?
    /// CPU 占用百分比 0–100。
    public let cpu: Double
    /// 内存占用百分比 0–100。
    public let mem: Double
    /// 常驻内存 RSS（字节）。
    public let memBytes: Int64?
    /// 线程数（`nlwp`）。
    public let threads: Int?
    /// 进程状态原始码（`stat`，首字符表状态：R/S/D/Z/T/I…）。
    public let state: String?
    /// 已运行秒数（`etimes`）。
    public let elapsedSeconds: Int64?

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        command: String,
        cpu: Double,
        mem: Double,
        ppid: Int32? = nil,
        user: String? = nil,
        fullCommand: String? = nil,
        memBytes: Int64? = nil,
        threads: Int? = nil,
        state: String? = nil,
        elapsedSeconds: Int64? = nil
    ) {
        self.pid = pid
        self.command = command
        self.cpu = cpu
        self.mem = mem
        self.ppid = ppid
        self.user = user
        self.fullCommand = fullCommand
        self.memBytes = memBytes
        self.threads = threads
        self.state = state
        self.elapsedSeconds = elapsedSeconds
    }
}
