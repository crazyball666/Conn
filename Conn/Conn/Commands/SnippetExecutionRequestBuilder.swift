import ConnKit
import ConnRunner
import ConnSSH
import Foundation

enum SnippetExecutionMode: Equatable {
    case silent
    case terminal
}

struct SnippetTerminalRoute: Hashable, Identifiable {
    let host: Host
    let preparedCommand: String

    var id: String { "\(host.id)#\(preparedCommand)" }
}

struct SnippetExecutionRequest {
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
    static func begin(errorText: inout String?) {
        errorText = nil
    }
}
