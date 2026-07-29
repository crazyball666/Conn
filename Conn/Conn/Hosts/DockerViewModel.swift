import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 分段外壳：可用性探测、sudo 标志、共用的结果提示，以及四个资源模型。
///
/// 它**不再直接持有任何资源列表**——容器、镜像、卷、网络各自一个模型，
/// 各管各的加载与状态。这样加第五类资源时只多一个文件，不动这里。
@Observable
@MainActor
final class DockerViewModel {
    enum LoadState: Equatable {
        case loading
        case unavailable(DockerAvailability)
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    /// 首次加载后置真——切换分段时不再自动重拉（改下拉刷新）。
    private(set) var hasLoaded = false
    var actionMessage: String?

    // 下面三个隐式解包可选值并非疏忽：`context` 的 report/audit 闭包要弱引用
    // 捕获 self，而 `containers`/`images` 又是拿 `context` 构造的——三者必须在
    // init 里互相依赖着赋值，Swift 的两段式初始化要求它们在此之前"已经有值"
    // （哪怕是隐式 nil）才允许捕获 self。改成普通 Optional 会让每个调用点都要
    // 多一层 `?`，偏离了 Step 1 清单里那些无需判空的调用写法。
    // swiftlint:disable:next implicitly_unwrapped_optional
    private(set) var containers: DockerContainersModel!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private(set) var images: DockerImagesModel!

    private let host: Host
    private let connectionManager: ConnectionManager
    private let runHistory: any RunHistoryRepository
    private var availability: DockerAvailability = .notInstalled
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var context: DockerContext!

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
        runHistory = dependencies.runHistory
        let manager = dependencies.connectionManager
        let currentHost = host
        context = DockerContext(
            session: { try await manager.session(for: currentHost) },
            sudo: false,
            isUsable: false,
            report: { [weak self] message in self?.actionMessage = message },
            audit: { [weak self] command, result in self?.audit(command: command, result: result) },
            reprobe: { [weak self] in await self?.load() }
        )
        containers = DockerContainersModel(context: context)
        images = DockerImagesModel(context: context)
    }

    /// 当前是否需 sudo（供容器日志沿用同一提权）。
    var usesSudo: Bool { availability.sudo }

    /// 仅首次加载（分段出现时调用）。已加载则跳过。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        hasLoaded = true
        loadState = .loading
        do {
            let session = try await connectionManager.session(for: host)
            let probe = try await DockerService.probe(on: session)
            availability = probe
            guard probe.isUsable else {
                loadState = .unavailable(probe)
                return
            }
            // 探测晚于上下文构造，sudo / isUsable 标志要回填给全部子模型
            propagateAvailability(probe)
            // 本次探测已经取过 session，直接传给容器加载，避免同一次 load() 里
            // 取两次会话（重构前的原行为：探测与列表共用一次 session）。
            try await containers.load(using: session)
            loadState = .ready
        } catch {
            loadState = .failed(error.friendlyDiagnosis)
        }
    }

    /// 回填 sudo / isUsable 标志——同时会重建全部子模型（`DockerContext` 是
    /// `struct`，`session` / `report` / `audit` / `reprobe` 均为值闭包，无法就地
    /// 改后传播，只能重建持有者）。
    ///
    /// **只能在任何列表加载之前调用**：此刻子模型都还是空列表，重建无损；
    /// 若未来在列表已加载后调用此方法，会悄悄清空用户正在看的数据。
    /// 目前唯一调用点在 `load()` 里、紧邻探测之后、`containers.load()` 之前，
    /// 正好满足这个前提。
    private func propagateAvailability(_ probe: DockerAvailability) {
        context.sudo = probe.sudo
        context.isUsable = probe.isUsable
        containers = DockerContainersModel(context: context)
        images = DockerImagesModel(context: context)
    }

    private func audit(command: String, result: ExecResult) {
        try? runHistory.record(RunHistoryEntry(
            hostUUID: host.id,
            command: command,
            exitCode: result.exitCode,
            outputHead: String(result.stdoutText.prefix(500))
        ))
    }
}
