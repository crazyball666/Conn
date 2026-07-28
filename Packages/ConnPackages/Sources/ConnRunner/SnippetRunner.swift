import ConnKit
import ConnSSH
import Foundation

/// 片段执行管线（方案 §4.6）。
///
/// 负责静默执行（exec，结果卡）与审计落库；危险判定复用 ConnSSH 的
/// `DangerCommandRules`（传输层不做语义判断，规则集中一处）。进终端执行由
/// App 层把最终命令喂给 `TerminalScreen(autoCommand:)`，不经此类。
public struct SnippetRunner {
    private let connectionManager: ConnectionManager
    private let runHistory: any RunHistoryRepository

    public init(connectionManager: ConnectionManager, runHistory: any RunHistoryRepository) {
        self.connectionManager = connectionManager
        self.runHistory = runHistory
    }

    /// 危险裁决。UI 据此决定是否二次确认（危险片段或生产敏感命令）。
    public func evaluateDanger(command: String, isProduction: Bool) -> DangerVerdict {
        DangerCommandRules.evaluate(command, isProduction: isProduction)
    }

    /// 片段静默执行的超时。
    ///
    /// 为什么给到 10 分钟（而不是 `exec(_:)` 默认的 30 秒）：这里跑的是**用户主动发起的
    /// 任意命令**——`apt upgrade -y`、`docker compose pull`、构建脚本，跑几分钟是常态，
    /// 不是异常。30 秒会把这些正常执行判成失败，而且超时并不会终止远端命令
    /// （见 `CitadelSession.exec`），用户只会看到「失败」却发现服务器上真跑完了，
    /// 甚至重试一次撞上还在跑的上一次。所以这里取全项目最宽松的一档：
    /// 上限只用来兜「会话已死、读取永不返回」，不用来限制命令本身该跑多久。
    private static let silentRunTimeout: Duration = .seconds(600)

    /// 静默执行最终命令并写审计。命令应已由 `Snippet.render(values:)` 填充完变量。
    public func runSilently(command: String, on host: ConnKit.Host) async throws -> RunOutcome {
        let session = try await connectionManager.session(for: host)
        let result = try await session.exec(command, timeout: Self.silentRunTimeout)
        let outcome = RunOutcome(
            command: command,
            exitCode: result.exitCode,
            stdout: result.stdoutText,
            stderr: result.stderrText
        )
        try? runHistory.record(RunHistoryEntry(
            hostUUID: host.id,
            command: command,
            exitCode: result.exitCode,
            outputHead: String(result.stdoutText.prefix(500))
        ))
        return outcome
    }
}
