import ConnKit
import ConnSSH
import ConnUI
import Foundation
import Observation

/// 用户在终端连接卡片中看到的阶段。具体列表由 Host 的连接路径决定。
public enum TerminalConnectionStepID: String, CaseIterable, Sendable {
    case profile
    case credential
    case state
    case route
    case socks
    case network
    case authentication
    case shell
    case ready
}

public enum TerminalConnectionStepState: Sendable, Equatable {
    case pending
    case active
    case completed
    case failed
}

public struct TerminalConnectionStep: Identifiable, Sendable, Equatable {
    public let id: TerminalConnectionStepID
    public var state: TerminalConnectionStepState
    public var detail: String?
    public var durationMs: Int?
    /// 仅用于计算耗时，不进入 UI。
    var startedAt: Date?

    public init(
        id: TerminalConnectionStepID,
        state: TerminalConnectionStepState = .pending,
        detail: String? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.state = state
        self.detail = detail
        self.durationMs = durationMs
    }
}

public enum TerminalConnectionLogLevel: Sendable, Equatable {
    case info
    case success
    case error
}

public struct TerminalConnectionLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let level: TerminalConnectionLogLevel

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        message: String,
        level: TerminalConnectionLogLevel = .info
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.level = level
    }
}

public enum TerminalConnectionKind: Sendable, Equatable {
    case connect
    case reconnect
    case restore
}

public enum TerminalConnectionActivityState: Sendable, Equatable {
    case connecting
    case connected
    case failed
    case cancelled
}

/// 一次新建连接或重连的可观察进度。按 Host 保存，终端页只展示当前 Host 的最新活动。
public struct TerminalConnectionActivity: Identifiable, Sendable, Equatable {
    public let id: String
    public let hostID: String
    public let hostName: String
    public let hostAddress: String
    public let kind: TerminalConnectionKind
    public let routeLabel: String?
    public let routeDetail: String?
    public let connectionRef: String
    public let startedAt: Date
    public var state: TerminalConnectionActivityState
    public var steps: [TerminalConnectionStep]
    public var logs: [TerminalConnectionLogEntry]
    public var errorMessage: String?

    public var activeStep: TerminalConnectionStep? {
        steps.first { $0.state == .active }
    }

    public var failedStep: TerminalConnectionStep? {
        steps.first { $0.state == .failed }
    }

    var startedAtByStep: [TerminalConnectionStepID: Date]

    public init(
        id: String,
        hostID: String,
        hostName: String,
        hostAddress: String,
        kind: TerminalConnectionKind,
        routeLabel: String? = nil,
        routeDetail: String? = nil,
        connectionRef: String = "",
        startedAt: Date = .now,
        state: TerminalConnectionActivityState = .connecting,
        steps: [TerminalConnectionStep] = TerminalConnectionStepID.allCases.map {
            TerminalConnectionStep(id: $0)
        },
        logs: [TerminalConnectionLogEntry] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.hostAddress = hostAddress
        self.kind = kind
        self.routeLabel = routeLabel
        self.routeDetail = routeDetail
        self.connectionRef = connectionRef
        self.startedAt = startedAt
        self.state = state
        self.steps = steps
        self.logs = logs
        self.errorMessage = errorMessage
        startedAtByStep = [:]
    }
}

/// 进程内连接进度中心。只由 `TerminalSessionCoordinator` 写入，终端页和连接卡片只读。
@Observable
@MainActor
public final class TerminalConnectionProgressCenter {
    public private(set) var activities: [String: TerminalConnectionActivity] = [:]

    public init() {}

    public func activity(forID activityID: String) -> TerminalConnectionActivity? {
        activities[activityID]
    }

    public func begin(
        host: ConnKit.Host,
        kind: TerminalConnectionKind,
        activityID: String,
        connectionRef: String = ""
    ) {
        let route: (label: String, detail: String?)?
        var stepIDs: [TerminalConnectionStepID]
        if host.privateNetworkProfileID != nil {
            route = ("Headscale", "Tailscale")
            stepIDs = [.profile, .credential, .state, .route, .socks, .network, .authentication, .shell, .ready]
        } else if let proxy = host.proxyConfiguration {
            route = (L("代理"), "\(proxy.host):\(proxy.port)")
            stepIDs = [.route, .network, .authentication, .shell, .ready]
        } else if !host.jumpChain.isEmpty {
            route = (L("跳板"), "\(host.jumpChain.count)")
            stepIDs = [.route, .network, .authentication, .shell, .ready]
        } else {
            route = nil
            stepIDs = [.network, .authentication, .shell, .ready]
        }

        var steps = stepIDs.map { TerminalConnectionStep(id: $0) }
        if !steps.isEmpty {
            steps[0].state = .active
            steps[0].startedAt = .now
        }
        var activity = TerminalConnectionActivity(
            id: "\(host.id)-\(UUID().uuidString)",
            hostID: host.id,
            hostName: host.name,
            hostAddress: host.displayAddress,
            kind: kind,
            routeLabel: route?.label,
            routeDetail: route?.detail,
            connectionRef: connectionRef,
            steps: steps
        )
        activity.logs = [TerminalConnectionLogEntry(
            message: "\(L("连接中…")) \(host.displayAddress)"
        )]
        activities[activityID] = activity
    }

    /// 把底层已发出的连接阶段样本投影到当前活动。
    ///
    /// 私有网络会先发 profile/credential/state/route/socks，再发 ssh_handshake；
    /// 这里不预设它们一定存在，缺少样本的阶段由连接完成时的兜底补齐。
    public func record(_ sample: ConnectionPhaseSample) {
        guard !sample.context.connectionRef.isEmpty,
              let activityID = activities.first(where: {
                  $0.value.connectionRef == sample.context.connectionRef
              })?.key,
              var activity = activities[activityID]
        else { return }

        let phaseStep: TerminalConnectionStepID? = switch sample.phase {
        case "profile_load": .profile
        case "credential_load": .credential
        case "state_prepare": .state
        case "route_setup": .route
        case "socks_proxy": .socks
        case "ssh_handshake": .network
        case "pty_open": .shell
        case "terminal_ready": .ready
        default: nil
        }
        guard let phaseStep,
              let index = activity.steps.firstIndex(where: { $0.id == phaseStep })
        else { return }

        if sample.outcome == .failure {
            let failureStep: TerminalConnectionStepID =
                sample.errorCategory == "auth" || sample.errorCategory == "host_key"
                    ? .authentication
                    : phaseStep
            if let failureIndex = activity.steps.firstIndex(where: { $0.id == failureStep }) {
                for index in activity.steps.indices
                    where index != failureIndex && activity.steps[index].state == .active {
                    activity.steps[index].state = .completed
                    activity.steps[index].durationMs = duration(
                        from: activity.steps[index].startedAt ?? activity.startedAt,
                        to: .now
                    )
                }
                activity.steps[failureIndex].state = .failed
                activity.steps[failureIndex].durationMs = sample.durationMs
                activity.errorMessage = sample.errorText
            }
            activity.state = .failed
            if !sample.errorText.isEmpty {
                activity.logs.append(TerminalConnectionLogEntry(
                    message: sample.errorText,
                    level: .error
                ))
            }
        } else {
            activity.steps[index].state = .completed
            activity.steps[index].durationMs = sample.durationMs
            if sample.phase == "ssh_handshake",
               let authIndex = activity.steps.firstIndex(where: { $0.id == .authentication }) {
                activity.steps[authIndex].state = .completed
                activity.steps[authIndex].durationMs = sample.durationMs
            }
            if sample.phase == "terminal_ready" {
                activity.state = .connected
            }
            if let nextIndex = activity.steps.indices.first(where: {
                $0 > index && activity.steps[$0].state == .pending
            }) {
                activity.steps[nextIndex].state = .active
                activity.steps[nextIndex].startedAt = .now
            }
        }
        activities[activityID] = activity
    }

    /// 底层没有逐阶段上报时，在连接完成后补齐路由相关阶段，避免卡片停在半截。
    public func completePendingRouteStages(forID activityID: String) {
        guard var activity = activities[activityID] else { return }
        let routeSteps: Set<TerminalConnectionStepID> = [.profile, .credential, .state, .route, .socks]
        let now = Date()
        for index in activity.steps.indices where routeSteps.contains(activity.steps[index].id) {
            guard activity.steps[index].state != .failed else { continue }
            activity.steps[index].state = .completed
            if activity.steps[index].durationMs == nil {
                activity.steps[index].durationMs = duration(
                    from: activity.steps[index].startedAt ?? activity.startedAt,
                    to: now
                )
            }
        }
        activities[activityID] = activity
    }

    public func activate(
        _ step: TerminalConnectionStepID,
        forID activityID: String,
        detail: String? = nil
    ) {
        guard var activity = activities[activityID] else { return }
        let now = Date()
        for index in activity.steps.indices {
            if activity.steps[index].id == step {
                if activity.steps[index].state != .completed {
                    activity.steps[index].state = .active
                    activity.steps[index].startedAt = activity.steps[index].startedAt ?? now
                }
                if let detail {
                    activity.steps[index].detail = detail
                }
            } else if activity.steps[index].state == .active {
                // 后一个阶段开始意味着前一个阶段已经可用；避免同时出现两个转圈。
                activity.steps[index].state = .completed
                activity.steps[index].durationMs = duration(
                    from: activity.steps[index].startedAt,
                    to: now
                )
            }
        }
        if let detail {
            activity.logs.append(TerminalConnectionLogEntry(message: detail))
        }
        activities[activityID] = activity
    }

    public func complete(
        _ step: TerminalConnectionStepID,
        forID activityID: String,
        detail: String? = nil
    ) {
        guard var activity = activities[activityID] else { return }
        let now = Date()
        guard let index = activity.steps.firstIndex(where: { $0.id == step }) else { return }
        if activity.steps[index].state != .failed {
            activity.steps[index].state = .completed
        }
        if activity.steps[index].durationMs == nil {
            activity.steps[index].durationMs = duration(
                from: activity.steps[index].startedAt ?? activity.startedAt,
                to: now
            )
        }
        if let detail {
            activity.steps[index].detail = detail
            activity.logs.append(TerminalConnectionLogEntry(message: detail, level: .success))
        }
        activities[activityID] = activity
    }

    public func fail(
        forID activityID: String,
        step preferredStep: TerminalConnectionStepID? = nil,
        message: String,
        category: String = ""
    ) {
        guard var activity = activities[activityID] else { return }
        if activity.state == .failed { return }
        let now = Date()
        let step = preferredStep ?? activity.activeStep?.id ?? .network
        for index in activity.steps.indices
            where activity.steps[index].id != step && activity.steps[index].state == .active {
            activity.steps[index].state = .completed
            activity.steps[index].durationMs = duration(
                from: activity.steps[index].startedAt ?? activity.startedAt,
                to: now
            )
        }
        if let index = activity.steps.firstIndex(where: { $0.id == step }) {
            activity.steps[index].state = .failed
            activity.steps[index].durationMs = duration(
                from: activity.steps[index].startedAt ?? activity.startedAt,
                to: now
            )
            if !message.isEmpty {
                activity.steps[index].detail = message
            }
        }
        activity.state = .failed
        activity.errorMessage = message
        activity.logs.append(TerminalConnectionLogEntry(
            message: message.isEmpty ? L("连接失败") : message,
            level: .error
        ))
        if !category.isEmpty {
            activity.logs.append(TerminalConnectionLogEntry(
                message: category,
                level: .error
            ))
        }
        activities[activityID] = activity
    }

    public func finish(forID activityID: String) {
        guard var activity = activities[activityID] else { return }
        let now = Date()
        for index in activity.steps.indices where activity.steps[index].state != .failed {
            if activity.steps[index].durationMs == nil {
                activity.steps[index].durationMs = duration(
                    from: activity.steps[index].startedAt ?? activity.startedAt,
                    to: now
                )
            }
            activity.steps[index].state = .completed
        }
        activity.state = .connected
        activity.logs.append(TerminalConnectionLogEntry(
            message: L("已连接"),
            level: .success
        ))
        activities[activityID] = activity
    }

    public func cancel(forID activityID: String) {
        guard var activity = activities[activityID] else { return }
        activity.state = .cancelled
        activity.logs.append(TerminalConnectionLogEntry(
            message: L("取消"),
            level: .info
        ))
        activities[activityID] = activity
    }

    private func duration(from start: Date?, to end: Date) -> Int {
        guard let start else { return 0 }
        return max(0, Int(end.timeIntervalSince(start) * 1000))
    }
}
