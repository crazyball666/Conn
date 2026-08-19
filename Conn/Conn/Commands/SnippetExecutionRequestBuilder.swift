import ConnKit
import ConnRunner
import ConnSSH
import Foundation

enum SnippetExecutionMode: Equatable, Sendable {
    case silent
    case terminal
}

struct SnippetTerminalRoute: Hashable, Identifiable, Sendable {
    let host: Host
    let preparedCommand: String

    var id: String { "\(host.id)#\(preparedCommand)" }
}

struct SnippetExecutionRequest: Sendable {
    let mode: SnippetExecutionMode
    let hosts: [Host]
    let plansByHostID: [String: SnippetExecutionPlan]

    var terminalRoute: SnippetTerminalRoute? {
        guard mode == .terminal,
              hosts.count == 1,
              let host = hosts.first,
              let plan = plansByHostID[host.id] else {
            return nil
        }
        return SnippetTerminalRoute(
            host: host,
            preparedCommand: plan.preparedCommand
        )
    }
}

enum SnippetExecutionPreparationResult: Sendable {
    case ready(SnippetExecutionRequest)
    case blocked(hostName: String, report: RemoteCapabilityReport)
}

enum SnippetExecutionPlanningError: LocalizedError {
    case missingPreparation(hostName: String)
    case preparationTargetMismatch(hostName: String)

    var errorDescription: String? {
        switch self {
        case let .missingPreparation(hostName):
            "\(hostName)：\(L("执行失败"))"
        case let .preparationTargetMismatch(hostName):
            "\(hostName)：\(L("主机连接配置已变化，请重新检查后执行"))"
        }
    }
}

enum SnippetExecutionRequestBuilder {
    /// 用户点击执行后才连接主机并准备实际运行环境。主机选择本身只修改本地选择，
    /// 不发起平台兼容性探测或远端命令。
    static func prepare(
        mode: SnippetExecutionMode,
        hosts: [Host],
        snippet: Snippet,
        renderedScript: String,
        planner: SnippetExecutionPlanner
    ) async throws -> SnippetExecutionPreparationResult {
        var resultsByHostID: [String: SnippetHostPreparationResult] = [:]
        try await withThrowingTaskGroup(
            of: (String, SnippetHostPreparationResult).self
        ) { group in
            for host in hosts {
                group.addTask {
                    let result = try await planner.prepare(snippet: snippet, on: host)
                    return (host.id, result)
                }
            }
            for try await (hostID, result) in group {
                resultsByHostID[hostID] = result
            }
        }

        var preparations: [String: SnippetHostPreparation] = [:]
        for host in hosts {
            guard let result = resultsByHostID[host.id] else {
                throw SnippetExecutionPlanningError.missingPreparation(hostName: host.name)
            }
            switch result {
            case let .ready(preparation):
                preparations[host.id] = preparation
            case let .blocked(report):
                return .blocked(hostName: host.name, report: report)
            }
        }

        return .ready(try build(
            mode: mode,
            hosts: hosts,
            preparationByHostID: preparations,
            renderedScript: renderedScript,
            planner: planner
        ))
    }

    static func build(
        mode: SnippetExecutionMode,
        hosts: [Host],
        preparationByHostID: [String: SnippetHostPreparation],
        renderedScript: String,
        planner: SnippetExecutionPlanner
    ) throws -> SnippetExecutionRequest {
        var plansByHostID: [String: SnippetExecutionPlan] = [:]
        for host in hosts {
            guard let preparation = preparationByHostID[host.id] else {
                throw SnippetExecutionPlanningError.missingPreparation(
                    hostName: host.name
                )
            }
            guard preparation.connectionIdentity == SSHConnectionIdentity(host: host) else {
                throw SnippetExecutionPlanningError.preparationTargetMismatch(
                    hostName: host.name
                )
            }
            plansByHostID[host.id] = try planner.makeExecutionPlan(
                renderedScript: renderedScript,
                from: preparation
            )
        }
        return SnippetExecutionRequest(
            mode: mode,
            hosts: hosts,
            plansByHostID: plansByHostID
        )
    }
}

enum SnippetExecutionAttemptFeedback {
    /// 新一轮执行从用户点击按钮的当下开始。连接和运行环境准备也属于本轮执行，
    /// 因此必须同步清掉上一轮展示，不能让旧结果在准备阶段继续冒充当前结果。
    static func begin(
        errorText: inout String?,
        outcome: inout RunOutcome?,
        batchResults: inout [ScriptBatchResult]
    ) {
        errorText = nil
        outcome = nil
        batchResults = []
    }
}
