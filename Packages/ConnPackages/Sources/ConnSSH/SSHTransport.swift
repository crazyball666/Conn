import Foundation

/// 会话状态流的事件。
public enum SSHSessionState: Sendable, Equatable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case closed
}

/// 引擎可替换的传输总抽象（技术方案 §4.1）。
///
/// Citadel 与（潜在的）libssh2 都实现此协议；`MockSSHTransport` 亦然，
/// 供演示模式与测试整体替换。上层永远只见此协议，不见具体引擎。
public protocol SSHTransport: Sendable {
    func connect(
        _ endpoint: SSHEndpoint,
        username: String,
        auth: SSHAuth,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession
}

/// 一条已建立的 SSH 会话。
public protocol SSHSession: AnyObject, Sendable {
    /// 执行一条命令，等待完整结果。
    func exec(_ command: String, timeout: Duration) async throws -> ExecResult

    /// 执行一条命令，按块流式返回 stdout（日志跟随、docker logs -f 用）。
    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error>

    /// 开一个交互式 PTY（终端用，Phase 4 深用）。
    func openShell(term: TermSize) async throws -> any ShellChannel

    /// 打开 SFTP 子系统（文件管理，Phase 6）。
    func sftp() async throws -> any RemoteFileSystem

    /// 开到目标的 direct-tcpip 隧道（跳板链 / 端口转发共用）。
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel

    /// 会话状态流。
    var state: AsyncStream<SSHSessionState> { get }

    /// 主动关闭会话。
    func close() async
}

public extension SSHSession {
    /// 便利重载：默认 30s 超时。
    ///
    /// 只适用于**短命令**（探测、取指标、读状态）。用户发起的任意命令、docker 写操作与
    /// 清理等「跑几分钟属正常」的调用点，必须显式传更长的值——否则会把正常执行判成失败，
    /// 而超时并不会终止远端命令（见 `CitadelSession.exec`）。
    ///
    /// 下限也有约束：Citadel 建通道阶段不响应取消，只有它自带的 15 秒兜底，
    /// **传低于 15 秒的值会让那层兜底失效**（详见 ConnSSHCitadel 的 `withTimeout` 说明）。
    func exec(_ command: String) async throws -> ExecResult {
        try await exec(command, timeout: .seconds(30))
    }
}

/// 交互式 shell 通道（Phase 4 终端用）。
public protocol ShellChannel: AnyObject, Sendable {
    func write(_ bytes: Data) async throws
    func resize(_ size: TermSize) async throws
    var output: AsyncThrowingStream<Data, Error> { get }
    func close() async
}

/// direct-tcpip 隧道（跳板链 / 端口转发用）。
public protocol SSHTunnel: AnyObject, Sendable {
    func close() async
}
