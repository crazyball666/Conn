import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 容器列表与动作。
///
/// 从 `DockerViewModel` 拆出：那个类型原本同时管可用性探测、容器、镜像、
/// 动作与弹窗，再塞进卷与网络会奔着 500 行去，四类资源的加载状态也互相纠缠。
@Observable
@MainActor
final class DockerContainersModel {
    private(set) var items: [ContainerInfo] = []
    /// 正在执行操作的容器 id（禁用该行按钮 + 显示忙碌）。
    private(set) var busyContainerID: String?
    /// 待确认删除的容器（rm 强确认，方案 §4.4）。
    var pendingRemoval: ContainerInfo?

    private let context: DockerContext

    init(context: DockerContext) {
        self.context = context
    }

    /// - Parameter session: 外壳做完可用性探测后已经取到的会话，传进来复用，
    ///   避免一次 `load()` 里取两次会话（重构前的原行为）。子模型自身的其它调用点
    ///   （如 `refresh()`）不持有现成会话，省略此参数、内部自取。
    func load(using session: (any SSHSession)? = nil) async throws {
        // `??` 的右侧是 autoclosure，不支持 async 调用，只能手写 if-let。
        let resolvedSession: any SSHSession
        if let session {
            resolvedSession = session
        } else {
            resolvedSession = try await context.session()
        }
        items = try await DockerService.list(on: resolvedSession, sudo: context.sudo)
    }

    /// 下拉刷新：静默重拉，不切加载态——保留列表、避免闪烁。
    /// 失败时保留上次结果，仅弹提示。
    ///
    /// Docker 已探测为不可用时不再直接拉列表，而是回到外壳重新探测、翻到
    /// 「不可用」引导页——重构前 `refreshContainers()` 的既有行为。
    func refresh() async {
        guard context.isUsable else {
            await context.reprobe()
            return
        }
        do {
            try await load()
        } catch {
            context.report(String(format: L("%@ 失败：%@"), L("刷新"), error.friendlyDiagnosis))
        }
    }

    func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        busyContainerID = container.id
        defer { busyContainerID = nil }
        do {
            let result = try await DockerService.perform(
                action, id: container.id, on: context.session(), sudo: context.sudo
            )
            context.audit("docker \(action.verb) \(container.name)", result)
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            context.report(result.isSuccess
                ? String(format: L("%@ %@ 成功"), action.label, container.name)
                : String(format: L("%@ %@ 失败：%@"), action.label, container.name, detail))
            await refresh()
        } catch {
            context.report(String(format: L("%@ 失败：%@"), action.label, error.friendlyDiagnosis))
        }
    }

    func requestRemoval(_ container: ContainerInfo) {
        pendingRemoval = container
    }

    func confirmRemoval() async {
        guard let container = pendingRemoval else { return }
        pendingRemoval = nil
        await perform(.remove, on: container)
    }

    /// 容器详情（inspect）——供详情页加载。
    func detail(for container: ContainerInfo) async -> ContainerDetail? {
        do {
            return try await DockerService.inspect(
                id: container.id, on: context.session(), sudo: context.sudo
            )
        } catch {
            return nil
        }
    }

    /// 进入容器控制台的命令（PTY 里 exec）。
    func consoleCommand(for container: ContainerInfo) -> String {
        DockerCommand.console(id: container.id, sudo: context.sudo)
    }
}
