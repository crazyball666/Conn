import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 容器管理 ViewModel（Phase 8）。
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
    private(set) var containers: [ContainerInfo] = []
    /// 正在执行操作的容器 id（禁用该行按钮 + 显示忙碌）。
    private(set) var busyContainerID: String?
    /// 待确认删除的容器（rm 强确认，方案 §4.4）。
    var pendingRemoval: ContainerInfo?
    var actionMessage: String?

    // 镜像
    private(set) var images: [ImageInfo] = []
    private(set) var imagesLoaded = false
    private(set) var imagesError: String?
    private(set) var busyImageID: String?
    var pendingImageRemoval: ImageInfo?

    private let host: Host
    private let connectionManager: ConnectionManager
    private let runHistory: any RunHistoryRepository
    private var availability: DockerAvailability = .notInstalled

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
        runHistory = dependencies.runHistory
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
            containers = try await DockerService.list(on: session, sudo: probe.sudo)
            loadState = .ready
        } catch {
            loadState = .failed(friendly(error))
        }
    }

    /// 下拉刷新容器：静默重拉，不切 `.loading`——保留分段与列表、避免闪烁。
    /// 失败时保留上次结果，仅弹提示。
    func refreshContainers() async {
        guard availability.isUsable else { await load(); return }
        do {
            let session = try await connectionManager.session(for: host)
            containers = try await DockerService.list(on: session, sudo: availability.sudo)
        } catch {
            actionMessage = String(format: L("%@ 失败：%@"), L("刷新"), friendly(error))
        }
    }

    func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        busyContainerID = container.id
        defer { busyContainerID = nil }
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await DockerService.perform(action, id: container.id, on: session, sudo: availability.sudo)
            audit(command: "docker \(action.verb) \(container.name)", result: result)
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            actionMessage = result.isSuccess
                ? String(format: L("%@ %@ 成功"), action.label, container.name)
                : String(format: L("%@ %@ 失败：%@"), action.label, container.name, detail)
            await refreshContainers()
        } catch {
            actionMessage = String(format: L("%@ 失败：%@"), action.label, friendly(error))
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
            let session = try await connectionManager.session(for: host)
            return try await DockerService.inspect(id: container.id, on: session, sudo: availability.sudo)
        } catch {
            return nil
        }
    }

    /// 进入容器控制台的命令（PTY 里 exec）。
    func consoleCommand(for container: ContainerInfo) -> String {
        DockerCommand.console(id: container.id, sudo: availability.sudo)
    }

    // MARK: - 镜像

    /// 仅首次加载镜像（镜像分段出现时调用）。
    func loadImagesIfNeeded() async {
        guard !imagesLoaded else { return }
        await loadImages()
    }

    func loadImages() async {
        guard availability.isUsable else { return }
        do {
            let session = try await connectionManager.session(for: host)
            images = try await DockerService.listImages(on: session, sudo: availability.sudo)
            imagesError = nil
        } catch {
            imagesError = friendly(error)
        }
        imagesLoaded = true
    }

    func requestImageRemoval(_ image: ImageInfo) {
        pendingImageRemoval = image
    }

    func confirmImageRemoval() async {
        guard let image = pendingImageRemoval else { return }
        pendingImageRemoval = nil
        busyImageID = image.id
        defer { busyImageID = nil }
        await runImageOp(String(format: L("删除镜像 %@"), image.displayName)) { session, sudo in
            try await DockerService.removeImage(reference: image.reference, on: session, sudo: sudo)
        }
    }

    func pruneImages() async {
        await runImageOp(L("清理悬空镜像")) { session, sudo in
            try await DockerService.pruneImages(on: session, sudo: sudo)
        }
    }

    /// 镜像写操作统一执行 + 审计 + 刷新 + 结果提示。
    private func runImageOp(
        _ label: String,
        _ operation: (any SSHSession, Bool) async throws -> ExecResult
    ) async {
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await operation(session, availability.sudo)
            audit(command: label, result: result)
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            actionMessage = result.isSuccess
                ? String(format: L("%@ 成功"), label)
                : String(format: L("%@ 失败：%@"), label, detail)
            await loadImages()
        } catch {
            actionMessage = String(format: L("%@ 失败：%@"), label, friendly(error))
        }
    }

    // MARK: - 私有

    private func audit(command: String, result: ExecResult) {
        try? runHistory.record(RunHistoryEntry(
            hostUUID: host.id,
            command: command,
            exitCode: result.exitCode,
            outputHead: String(result.stdoutText.prefix(500))
        ))
    }

    private func friendly(_ error: Error) -> String {
        if let sshError = error as? SSHError {
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? sshError.diagnosis
        }
        return error.localizedDescription
    }
}
