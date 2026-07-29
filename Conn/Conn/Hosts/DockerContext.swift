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
    /// 上报一条给用户看的结果（外壳统一弹 alert）。
    let report: (String) -> Void
    /// 写运行审计。
    let audit: (String, ExecResult) -> Void
}
