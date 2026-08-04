import ConnKit
import ConnSSH
import Foundation

public enum SnippetRunnerError: LocalizedError, Equatable {
    case auditUnavailable
    case auditUpdateFailed

    public var errorDescription: String? {
        switch self {
        case .auditUnavailable:
            L("无法保存执行记录，未执行脚本")
        case .auditUpdateFailed:
            L("脚本已执行，但执行记录保存失败")
        }
    }
}

/// 一次脚本批量执行的单主机结果。
public struct ScriptBatchResult: Identifiable, Sendable, Equatable {
    public let hostID: String
    public let hostName: String
    public let outcome: RunOutcome?
    public let errorMessage: String?

    public var id: String { hostID }
    public var isSuccess: Bool { outcome?.isSuccess == true && errorMessage == nil }

    public init(hostID: String, hostName: String, outcome: RunOutcome? = nil, errorMessage: String? = nil) {
        self.hostID = hostID
        self.hostName = hostName
        self.outcome = outcome
        self.errorMessage = errorMessage
    }
}

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
    public func evaluateDanger(script: String, isProduction: Bool) -> DangerVerdict {
        DangerCommandRules.evaluate(script, isProduction: isProduction)
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

    /// 静默执行最终脚本并写审计。脚本应已由 `Snippet.render(values:)` 填充完变量。
    public func runSilently(
        script: String,
        interpreter: ShellInterpreter = .sh,
        on host: ConnKit.Host
    ) async throws -> RunOutcome {
        let pending = RunHistoryEntry(
            hostUUID: host.id,
            script: script,
            interpreter: interpreter,
            state: .pending
        )
        do {
            try runHistory.record(pending)
        } catch {
            throw SnippetRunnerError.auditUnavailable
        }

        do {
            let session = try await connectionManager.session(for: host)
            let result = try await session.execScript(
                script,
                interpreter: interpreter,
                timeout: Self.silentRunTimeout
            )
            let outcome = RunOutcome(
                script: script,
                interpreter: interpreter,
                exitCode: result.exitCode,
                stdout: result.stdoutText,
                stderr: result.stderrText
            )
            let final = RunHistoryEntry(
                id: pending.id,
                hostUUID: pending.hostUUID,
                script: pending.script,
                interpreter: pending.interpreter,
                exitCode: result.exitCode,
                outputHead: String(result.stdoutText.prefix(500)),
                state: .known,
                ranAt: pending.ranAt
            )
            do {
                try runHistory.update(final)
            } catch {
                throw SnippetRunnerError.auditUpdateFailed
            }
            return outcome
        } catch {
            let unknown = RunHistoryEntry(
                id: pending.id,
                hostUUID: pending.hostUUID,
                script: pending.script,
                interpreter: pending.interpreter,
                state: .unknown,
                ranAt: pending.ranAt
            )
            try? runHistory.update(unknown)
            throw error
        }
    }

    /// 并发执行同一脚本到多台主机。单台失败不会阻塞其他主机，并为每台主机返回独立结果。
    public func runBatchSilently(
        script: String,
        interpreter: ShellInterpreter = .sh,
        on hosts: [ConnKit.Host]
    ) async -> [ScriptBatchResult] {
        await withTaskGroup(of: ScriptBatchResult.self, returning: [ScriptBatchResult].self) { group in
            for host in hosts {
                group.addTask { [self] in
                    do {
                        let outcome = try await runSilently(script: script, interpreter: interpreter, on: host)
                        return ScriptBatchResult(hostID: host.id, hostName: host.name, outcome: outcome)
                    } catch {
                        return ScriptBatchResult(
                            hostID: host.id,
                            hostName: host.name,
                            errorMessage: Self.errorMessage(for: error)
                        )
                    }
                }
            }
            var results: [ScriptBatchResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
        }
    }

    private static func errorMessage(for error: Error) -> String {
        if let sshError = error as? SSHError {
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? L("执行失败")
        }
        return error.localizedDescription
    }
}
