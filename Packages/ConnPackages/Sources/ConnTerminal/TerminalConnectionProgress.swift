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
    var hasSampleDuration = false

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

/// 一次新建、恢复或重连终端的可观察进度。
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
    public var endedAt: Date?
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
        endedAt: Date? = nil,
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
        self.endedAt = endedAt
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
    /// 复用连接时可能省略前置阶段。后续样本可以确认这些阶段已就绪，
    /// 只有实际收到样本的阶段使用样本中的耗时。
    public func record(_ sample: ConnectionPhaseSample) {
        guard !sample.context.connectionRef.isEmpty,
              let activityID = activities.first(where: {
                  $0.value.connectionRef == sample.context.connectionRef
              })?.key,
              var activity = activities[activityID],
              activity.state == .connecting
        else { return }

        if sample.outcome == .cancelled {
            cancel(forID: activityID)
            return
        }

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

        let authenticationIndex = activity.steps.firstIndex { $0.id == .authentication }
        switch sample.outcome {
        case .failure where !sample.isFinalFailure:
            if activity.steps[index].state == .pending {
                completePredecessors(in: &activity, before: index)
                activity.steps[index].state = .active
                activity.steps[index].startedAt = .now
            }
            if !sample.errorText.isEmpty {
                activity.logs.append(TerminalConnectionLogEntry(message: sample.errorText, level: .error))
            }
        case .failure:
            let isAuthenticationError = sample.errorCategory == "auth" || sample.errorCategory == "host_key"
            setFailure(
                in: &activity,
                at: isAuthenticationError ? authenticationIndex ?? index : index,
                message: sample.errorText,
                sampleDurationMs: sample.durationMs
            )
        case .success:
            guard !activity.steps[index].hasSampleDuration else { return }
            let lastCompletedIndex = phaseStep == .network ? authenticationIndex ?? index : index
            completePredecessors(in: &activity, before: lastCompletedIndex + 1)
            activity.steps[index].durationMs = sample.durationMs
            activity.steps[index].hasSampleDuration = true
            if activity.activeStep == nil,
               let nextIndex = activity.steps.firstIndex(where: { $0.state == .pending }) {
                activity.steps[nextIndex].state = .active
                activity.steps[nextIndex].startedAt = .now
            }
        case .cancelled:
            return
        }
        activities[activityID] = activity
    }

    /// 底层没有逐阶段上报时，在连接完成后补齐路由相关阶段，避免卡片停在半截。
    public func completePendingRouteStages(forID activityID: String) {
        guard var activity = activities[activityID],
              activity.state == .connecting,
              let networkIndex = activity.steps.firstIndex(where: { $0.id == .network }),
              networkIndex > 0
        else { return }
        completePredecessors(in: &activity, before: networkIndex)
        activities[activityID] = activity
    }

    public func activate(
        _ step: TerminalConnectionStepID,
        forID activityID: String,
        detail: String? = nil
    ) {
        guard var activity = activities[activityID],
              activity.state == .connecting,
              let index = activity.steps.firstIndex(where: { $0.id == step }),
              activity.steps[index].state != .completed
        else { return }
        completePredecessors(in: &activity, before: index)
        if activity.steps[index].state == .pending {
            activity.steps[index].state = .active
            activity.steps[index].startedAt = .now
        }
        if let detail {
            activity.steps[index].detail = detail
            activity.logs.append(TerminalConnectionLogEntry(message: detail))
        }
        activities[activityID] = activity
    }

    public func complete(
        _ step: TerminalConnectionStepID,
        forID activityID: String,
        detail: String? = nil
    ) {
        guard var activity = activities[activityID],
              activity.state == .connecting,
              let index = activity.steps.firstIndex(where: { $0.id == step }),
              activity.steps[index].state != .completed
        else { return }
        if activity.steps[index].state == .active {
            activity.steps[index].durationMs = duration(
                from: activity.steps[index].startedAt,
                to: .now
            )
        }
        completePredecessors(in: &activity, before: index + 1)
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
        guard var activity = activities[activityID],
              activity.state == .connecting
        else { return }
        let index = activity.steps.firstIndex { $0.id == preferredStep }
            ?? activity.steps.firstIndex { $0.state == .active }
            ?? activity.steps.indices.last
        guard let index else { return }
        setFailure(in: &activity, at: index, message: message)
        if !category.isEmpty {
            activity.logs.append(TerminalConnectionLogEntry(message: category, level: .error))
        }
        activities[activityID] = activity
    }

    private func setFailure(
        in activity: inout TerminalConnectionActivity,
        at index: Int,
        message: String,
        sampleDurationMs: Int? = nil
    ) {
        let now = Date()
        completePredecessors(in: &activity, before: index)
        if let activeIndex = activity.steps.firstIndex(where: { $0.state == .active }),
           activeIndex > index {
            activity.steps[activeIndex].state = .pending
            activity.steps[activeIndex].startedAt = nil
        }
        let startedAt = activity.steps[index].state == .active ? activity.steps[index].startedAt : nil
        activity.steps[index].state = .failed
        activity.steps[index].durationMs = sampleDurationMs ?? duration(from: startedAt, to: now)
        if !message.isEmpty {
            activity.steps[index].detail = message
        }
        activity.state = .failed
        activity.endedAt = now
        activity.errorMessage = message
        activity.logs.append(TerminalConnectionLogEntry(
            message: message.isEmpty ? L("连接失败") : message,
            level: .error
        ))
    }

    public func finish(forID activityID: String) {
        guard var activity = activities[activityID],
              activity.state == .connecting
        else { return }
        completePredecessors(in: &activity, before: activity.steps.endIndex)
        activity.state = .connected
        activity.endedAt = .now
        activity.logs.append(TerminalConnectionLogEntry(
            message: L("已连接"),
            level: .success
        ))
        activities[activityID] = activity
    }

    public func cancel(forID activityID: String) {
        guard var activity = activities[activityID],
              activity.state == .connecting
        else { return }
        if let index = activity.steps.firstIndex(where: { $0.state == .active }) {
            activity.steps[index].state = .pending
            activity.steps[index].startedAt = nil
        }
        activity.state = .cancelled
        activity.endedAt = .now
        activity.logs.append(TerminalConnectionLogEntry(
            message: L("取消"),
            level: .info
        ))
        activities[activityID] = activity
    }

    private func completePredecessors(in activity: inout TerminalConnectionActivity, before index: Int) {
        for predecessor in activity.steps.indices.prefix(upTo: index) {
            activity.steps[predecessor].state = .completed
        }
    }

    private func duration(from start: Date?, to end: Date) -> Int? {
        guard let start else { return nil }
        return max(0, Int(end.timeIntervalSince(start) * 1000))
    }
}
