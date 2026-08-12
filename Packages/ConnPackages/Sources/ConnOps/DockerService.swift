import ConnKit
import ConnSSH
import Foundation

/// Docker 可用性（方案 §4.4：无权限给引导文案而非静默失败）。
public enum DockerAvailability: Sendable, Equatable {
    /// docker ps 可直接跑；`sudo` 表示需否 `sudo -n` 前缀。
    case available(sudo: Bool)
    /// 未安装 docker CLI。
    case notInstalled
    /// 装了但当前用户无权限、且无免密 sudo。
    case permissionDenied
    /// 装了、有权限，但 Docker 守护进程没在跑。
    case daemonNotRunning
    /// 当前尚无对应平台的 Docker CLI 适配器。
    case unsupportedPlatform

    /// 直接可用时用的 sudo 前缀标志；不可用时 false。
    public var sudo: Bool {
        if case let .available(sudo) = self { return sudo }
        return false
    }

    public var isUsable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 容器管理服务：所有操作必须消费平台 provider 探测产生的 runtime。
public enum DockerService {
    static let writeTimeout: Duration = .seconds(120)
    static let pullTimeout: Duration = .seconds(300)
    static let pruneTimeout: Duration = .seconds(300)

    /// 平台感知的 POSIX Docker 探测。Windows/Unknown 没有匹配 provider 时不执行命令。
    public static func probe(
        on session: any SSHSession,
        profile: RemotePlatformProfile
    ) async throws -> DockerProbeResult {
        try await probe(on: session, profile: profile, registry: .default)
    }

    /// 可注入平台注册表的探测入口；本轮只请求 POSIX Docker provider。
    public static func probe(
        on session: any SSHSession,
        profile: RemotePlatformProfile,
        registry: DockerEnvironmentProviderRegistry
    ) async throws -> DockerProbeResult {
        guard let provider = registry.provider(
            for: profile.kind,
            scriptFamily: .posix
        ) else {
            return DockerProbeResult(availability: .unsupportedPlatform, runtime: nil)
        }
        return try await provider.probe(on: session)
    }

    static func requireComposeSuccess(_ result: ExecResult) throws {
        guard result.exitCode == 0 else {
            throw DockerComposeError.commandFailed(
                exitCode: result.exitCode,
                message: result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            )
        }
    }
}
