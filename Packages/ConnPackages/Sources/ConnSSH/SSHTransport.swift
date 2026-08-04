import ConnKit
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

    /// 经跳板链连接到目标主机。默认实现只支持空链，避免测试和第三方引擎
    /// 在升级协议后悄悄忽略跳板配置。
    func connect(
        via hops: [SSHJumpHop],
        to target: SSHJumpHop,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession
}

public extension SSHTransport {
    func connect(
        via hops: [SSHJumpHop],
        to target: SSHJumpHop,
        hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        guard hops.isEmpty else { throw SSHError.jumpChainUnsupported }
        return try await connect(
            target.endpoint,
            username: target.username,
            auth: target.auth,
            hostKeyPolicy: hostKeyPolicy
        )
    }
}

/// 一条已建立的 SSH 会话。
public protocol SSHSession: AnyObject, Sendable {
    /// 执行一条命令，等待完整结果。
    func exec(_ command: String, timeout: Duration) async throws -> ExecResult

    /// 执行一条命令，按块流式返回 stdout（日志跟随、docker logs -f 用）。
    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error>

    /// 执行一条命令，实时返回 stdout/stderr，并在结束后提供最终退出结果。
    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream

    /// 开一个交互式 PTY（终端用，Phase 4 深用）。
    func openShell(term: TermSize) async throws -> any ShellChannel

    /// 打开 SFTP 子系统（文件管理，Phase 6）。
    func sftp() async throws -> any RemoteFileSystem

    /// 开到目标的 direct-tcpip 隧道（跳板链 / 端口转发共用）。
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel

    /// 会话状态流。
    var state: AsyncStream<SSHSessionState> { get }

    /// 底层通道是否仍然活着。**同步、廉价**，实现应只读一个标志位，不发网络请求。
    ///
    /// 连接池靠它决定能不能把池化会话交出去。App 退到后台期间系统会回收 socket，
    /// 而池里的条目对此一无所知；没有这道门控，回前台后每个调用方都会拿到一条
    /// 死连接并失败，且只有采集路径会在失败后 `invalidate`，其余调用方永远等不到
    /// 自愈——用户得先切到服务器页转一圈才能继续用。
    ///
    /// **不是充分判据**：它反映的是本地通道状态，对端悄悄消失（没有 FIN/RST）时
    /// 仍会是 true，那种半开连接要等一次写失败才暴露。
    var isConnected: Bool { get }

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

    /// 使用指定解释器执行完整 Shell 脚本。
    ///
    /// 通过 `-c` 将脚本作为一个整体交给解释器，避免多行脚本被 SSH 外层
    /// 命令拆开执行。解释器由受限枚举提供，不接受任意字符串。
    func execScript(
        _ script: String,
        interpreter: ShellInterpreter = .sh,
        timeout: Duration
    ) async throws -> ExecResult {
        try await exec(interpreter.invocation(for: script), timeout: timeout)
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
