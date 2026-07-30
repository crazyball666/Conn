import ConnKit
import ConnOps
import ConnSSH
import Foundation

/// 四个资源模型共享的依赖：取会话、当前是否需 sudo、上报结果、写审计。
///
/// 用一个轻量上下文而不是让每个子模型各自持有 `ConnectionManager` + `Host` +
/// `RunHistoryRepository`：sudo 标志由可用性探测决定、只有外壳知道，
/// 子模型每次都要用它，靠构造注入传三四个参数会很啰嗦且容易漏。
@MainActor
struct DockerContext {
    let session: () async throws -> any SSHSession
    /// 当前是否需 sudo -n 前缀。由可用性探测决定。
    var sudo: Bool
    /// 当前 Docker 是否可用。由可用性探测决定，探测晚于上下文构造，外壳要回填。
    var isUsable: Bool
    /// 上报一条给用户看的结果（外壳统一弹 alert）。
    let report: (String) -> Void
    /// 写运行审计。
    let audit: (String, ExecResult) -> Void
    /// 重新探测并加载（外壳的 `load()`）。容器刷新在发现 Docker 已不可用时要回到
    /// 这里，把界面翻到「不可用」引导页——这是重构前的既有行为。
    let reprobe: () async -> Void
}
