import ConnKit
import ConnOps
import ConnSSH
import Foundation

enum DockerContextError: Error, LocalizedError, Equatable {
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            L("Docker 运行环境尚未探测完成")
        }
    }
}

/// 四个资源模型与写操作模型共享的依赖：取会话、Docker 运行时、上报与定向刷新。
///
/// 用一个轻量上下文而不是让每个子模型各自持有 `ConnectionManager` + `Host` +
/// `DockerOperationsModel` 直接接收 `hostUUID` 与 `RunHistoryRepository`，避免读模型
/// 看到原始命令或 `ExecResult` 审计接口。运行时由可用性探测决定、只有外壳知道。
@MainActor
struct DockerContext {
    let session: () async throws -> any SSHSession
    /// 已探测到的 Docker CLI 路径与提权方式。
    var runtime: DockerRuntimeContext?
    /// 当前 Docker 是否可用。由可用性探测决定，探测晚于上下文构造，外壳要回填。
    var isUsable: Bool
    /// 上报一条给用户看的结果（外壳统一弹 alert）。
    let report: (String) -> Void
    /// 写操作得到已知终态后按影响范围静默刷新。
    let refresh: (DockerRefreshScope) async -> Void
    /// 重新探测并加载（外壳的 `load()`）。容器刷新在发现 Docker 已不可用时要回到
    /// 这里，把界面翻到「不可用」引导页——这是重构前的既有行为。
    let reprobe: () async -> Void
    /// Compose down 会让 Docker 的自动发现结果消失；执行前保留配置上下文，
    /// 这样成功后仍能从 App 里再次启动同一项目。
    let preserveComposeProject: (DockerComposeProject) -> Void

    init(
        session: @escaping () async throws -> any SSHSession,
        runtime: DockerRuntimeContext?,
        isUsable: Bool,
        report: @escaping (String) -> Void,
        refresh: @escaping (DockerRefreshScope) async -> Void,
        reprobe: @escaping () async -> Void,
        preserveComposeProject: @escaping (DockerComposeProject) -> Void = { _ in }
    ) {
        self.session = session
        self.runtime = runtime
        self.isUsable = isUsable
        self.report = report
        self.refresh = refresh
        self.reprobe = reprobe
        self.preserveComposeProject = preserveComposeProject
    }

    func requireRuntime() throws -> DockerRuntimeContext {
        guard let runtime else { throw DockerContextError.runtimeUnavailable }
        return runtime
    }
}
