import ConnKit
import Foundation

/// 一次连接尝试的通用诊断上下文。字段只描述连接路径，不绑定 Tailscale/Headscale。
public struct ConnectionDiagnosticsContext: Sendable, Equatable {
    public let connectionRef: String
    public let targetAddress: String
    public let targetPort: Int
    public let connectionKind: String
    public let transport: String
    public let route: String
    public let routeProvider: String
    public let routeReused: Bool
    public let sessionReused: Bool
    public let launchKind: String

    public init(
        connectionRef: String = UUID().uuidString,
        targetAddress: String = "",
        targetPort: Int = 0,
        connectionKind: String = "connection",
        transport: String = "ssh",
        route: String = "direct",
        routeProvider: String = "",
        routeReused: Bool = false,
        sessionReused: Bool = false,
        launchKind: String = "new"
    ) {
        self.connectionRef = connectionRef
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.connectionKind = connectionKind
        self.transport = transport
        self.route = route
        self.routeProvider = routeProvider
        self.routeReused = routeReused
        self.sessionReused = sessionReused
        self.launchKind = launchKind
    }

    public init(
        host: ConnKit.Host,
        connectionKind: String = "connection",
        launchKind: String = "new",
        sessionReused: Bool = false
    ) {
        let route: String
        if host.privateNetworkProfileID != nil {
            route = "private_network"
        } else if host.proxyConfiguration != nil {
            route = "proxy"
        } else if !host.jumpChain.isEmpty {
            route = "jump"
        } else {
            route = "direct"
        }
        self.init(
            targetAddress: host.address,
            targetPort: host.port,
            connectionKind: connectionKind,
            route: route,
            sessionReused: sessionReused,
            launchKind: launchKind
        )
    }

    public func with(
        route: String? = nil,
        routeProvider: String? = nil,
        routeReused: Bool? = nil,
        sessionReused: Bool? = nil
    ) -> ConnectionDiagnosticsContext {
        ConnectionDiagnosticsContext(
            connectionRef: connectionRef,
            targetAddress: targetAddress,
            targetPort: targetPort,
            connectionKind: connectionKind,
            transport: transport,
            route: route ?? self.route,
            routeProvider: routeProvider ?? self.routeProvider,
            routeReused: routeReused ?? self.routeReused,
            sessionReused: sessionReused ?? self.sessionReused,
            launchKind: launchKind
        )
    }
}

public struct ConnectionPhaseSample: Sendable {
    public enum Outcome: String, Sendable {
        case success
        case failure
        case cancelled
    }

    public let context: ConnectionDiagnosticsContext
    public let phase: String
    public let durationMs: Int
    public let outcome: Outcome
    public let errorStage: String
    public let errorCategory: String
    public let errorText: String

    public init(
        context: ConnectionDiagnosticsContext,
        phase: String,
        durationMs: Int,
        outcome: Outcome,
        errorStage: String = "",
        errorCategory: String = "",
        errorText: String = ""
    ) {
        self.context = context
        self.phase = phase
        self.durationMs = durationMs
        self.outcome = outcome
        self.errorStage = errorStage
        self.errorCategory = errorCategory
        self.errorText = errorText
    }
}

public struct ConnectionTimingSummary: Sendable {
    public let context: ConnectionDiagnosticsContext
    public let result: ConnectionPhaseSample.Outcome
    public let totalMs: Int
    public let errorStage: String
    public let errorCategory: String
    public let errorText: String

    public init(
        context: ConnectionDiagnosticsContext,
        result: ConnectionPhaseSample.Outcome,
        totalMs: Int,
        errorStage: String = "",
        errorCategory: String = "",
        errorText: String = ""
    ) {
        self.context = context
        self.result = result
        self.totalMs = totalMs
        self.errorStage = errorStage
        self.errorCategory = errorCategory
        self.errorText = errorText
    }
}

/// 包内只产生阶段样本；具体如何上报由 App 层决定。
public protocol ConnectionDiagnosticsSink: Sendable {
    func record(_ sample: ConnectionPhaseSample)
    func record(_ summary: ConnectionTimingSummary)
}

/// 把阶段耗时与错误映射成稳定、低基数的分类。
public enum ConnectionDiagnosticsText {
    public static func category(for error: Error) -> String {
        guard let ssh = error as? SSHError else { return "unknown" }
        switch ssh {
        case .connectionRefused, .dnsFailed, .timeout, .channelClosed:
            return "network"
        case .authFailed, .missingPrivateKey, .unsupportedByEngine:
            return "auth"
        case .hostKeyMismatch, .hostKeyStoreUnavailable:
            return "host_key"
        case .privateNetworkUnsupported, .privateNetworkUnavailable,
             .privateNetworkAndProxyConflict:
            return "private_network"
        case .proxyUnsupported, .proxyUnavailable, .proxyAuthenticationFailed:
            return "proxy"
        case .jumpChainUnsupported, .jumpChainFailed:
            return "jump"
        case .commandTimeout, .sftpError:
            return "remote"
        }
    }

    public static func text(for error: Error) -> String {
        if let ssh = error as? SSHError {
            return ssh.diagnosis
        }
        return String(describing: error)
    }
}
