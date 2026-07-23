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
    private(set) var containers: [ContainerInfo] = []
    /// 正在执行操作的容器 id（禁用该行按钮 + 显示忙碌）。
    private(set) var busyContainerID: String?
    /// 待确认删除的容器（rm 强确认，方案 §4.4）。
    var pendingRemoval: ContainerInfo?
    var actionMessage: String?

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

    func load() async {
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

    func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        busyContainerID = container.id
        defer { busyContainerID = nil }
        do {
            let session = try await connectionManager.session(for: host)
            let result = try await DockerService.perform(action, id: container.id, on: session, sudo: availability.sudo)
            audit(command: "docker \(action.verb) \(container.name)", result: result)
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            actionMessage = result.isSuccess
                ? "\(action.label) \(container.name) 成功"
                : "\(action.label) \(container.name) 失败：\(detail)"
            await load()
        } catch {
            actionMessage = "\(action.label) 失败：\(friendly(error))"
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
