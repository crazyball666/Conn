import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 唯一写入口：一条主机详情内所有 Docker 写命令共用一个闸门、审计格式与刷新规则。
/// 资源模型只负责读模型状态，并把旧入口委派到这里，避免出现并发写与各自猜测刷新范围。
@Observable
@MainActor
final class DockerOperationsModel {
    private(set) var activeOperation: DockerOperation?
    var pendingDestructiveAction: DockerPendingAction?

    private let context: DockerContext
    private let hostUUID: String
    private let runHistory: any RunHistoryRepository

    init(context: DockerContext, hostUUID: String, runHistory: any RunHistoryRepository) {
        self.context = context
        self.hostUUID = hostUUID
        self.runHistory = runHistory
    }

    var isBusy: Bool { activeOperation != nil }
    var activeContainerID: String? { activeOperation?.activeContainerID }
    var activeImageID: String? { activeOperation?.activeImageID }

    // MARK: - Existing write entry points

    func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        guard !action.isDestructive else {
            requestDestructiveAction(.removeContainer(container))
            return
        }
        await performConfirmed(action, on: container)
    }

    private func performConfirmed(_ action: ContainerAction, on container: ContainerInfo) async {
        let operation = DockerOperation.container(action: action, targetID: container.id)
        await execute(operation, label: String(format: L("%@容器"), action.label)) { session, sudo in
            try await DockerService.perform(action, id: container.id, on: session, sudo: sudo)
        }
    }

    private func removeImageConfirmed(_ image: ImageInfo) async {
        await execute(.removeImage(targetID: image.id), label: L("删除镜像")) { session, sudo in
            try await DockerService.removeImage(reference: image.reference, on: session, sudo: sudo)
        }
    }

    private func pruneImagesConfirmed() async {
        await execute(.pruneImages, label: L("清理悬空镜像")) { session, sudo in
            try await DockerService.pruneImages(on: session, sudo: sudo)
        }
    }

    // MARK: - Phase 2 write entry points

    func runContainer(_ draft: DockerRunDraft) async {
        guard draft.validate().isEmpty else {
            context.report(L("容器配置无效，未执行 Docker 操作"))
            return
        }
        await execute(.runContainer, label: L("创建容器")) { session, sudo in
            try await DockerService.runContainer(draft, on: session, sudo: sudo)
        }
    }

    func createVolume(_ draft: DockerVolumeDraft) async {
        guard draft.validate().isEmpty else {
            context.report(L("卷配置无效，未执行 Docker 操作"))
            return
        }
        await execute(.createVolume, label: L("创建卷")) { session, sudo in
            try await DockerService.createVolume(draft, on: session, sudo: sudo)
        }
    }

    private func removeVolumeConfirmed(name: String) async {
        await execute(.removeVolume, label: L("删除卷")) { session, sudo in
            try await DockerService.removeVolume(name: name, on: session, sudo: sudo)
        }
    }

    func createNetwork(_ draft: DockerNetworkDraft) async {
        guard draft.validate().isEmpty else {
            context.report(L("网络配置无效，未执行 Docker 操作"))
            return
        }
        await execute(.createNetwork, label: L("创建网络")) { session, sudo in
            try await DockerService.createNetwork(draft, on: session, sudo: sudo)
        }
    }

    private func removeNetworkConfirmed(name: String) async {
        await execute(.removeNetwork, label: L("删除网络")) { session, sudo in
            try await DockerService.removeNetwork(name: name, on: session, sudo: sudo)
        }
    }

    private func systemPruneConfirmed(_ options: DockerSystemPruneOptions) async {
        await execute(.systemPrune, label: L("清理 Docker 资源")) { session, sudo in
            try await DockerService.systemPrune(options, on: session, sudo: sudo)
        }
    }

    /// 拉取是唯一流式写操作：远端启动前先同步写 pending；若本地审计不可用，就宁可不发
    /// 命令，避免制造无法追踪的长任务。
    func pullImage(reference: String, onChunk: @escaping (String) -> Void) async {
        let operation = DockerOperation.pullImage
        guard begin(operation) else { return }
        defer { activeOperation = nil }

        let pending = DockerAuditSummary(operation: operation.auditOperation, state: .unknown)
            .historyEntry(hostUUID: hostUUID)
        let pendingEntry = RunHistoryEntry(
            id: pending.id,
            hostUUID: pending.hostUUID,
            command: pending.command,
            exitCode: nil,
            outputHead: nil,
            state: .pending,
            ranAt: pending.ranAt
        )
        do {
            try runHistory.record(pendingEntry)
        } catch {
            context.report(L("无法保存拉取审计，未开始拉取"))
            return
        }

        do {
            let session = try await context.session()
            let stream = try await DockerService.pullImage(reference: reference, on: session, sudo: context.sudo)
            // 输出流故障并不必然代表远端没有终态；仍等待 result()，只要拿到最终
            // ExecResult 就按 known 处理。没有 result 才是 unknown。
            do {
                for try await chunk in stream.output {
                    // SSH 输出可能含截断 UTF-8；与 ExecResult 一样保留可读部分。
                    // swiftlint:disable:next optional_data_string_conversion
                    onChunk(String(decoding: chunk, as: UTF8.self))
                }
            } catch {
                // result() below remains the authority for result certainty.
            }
            let result = try await stream.result()
            let state = DockerOperationResultState.known(exitCode: result.exitCode)
            let finalEntry = DockerAuditSummary(operation: operation.auditOperation, state: state, ranAt: pending.ranAt)
                .historyEntry(hostUUID: hostUUID, id: pendingEntry.id)
            let auditSaved = update(finalEntry)
            reportKnown(label: L("拉取镜像"), state: state, auditSaved: auditSaved)
            await context.refresh(operation.refreshScope)
        } catch {
            let finalEntry = DockerAuditSummary(
                operation: operation.auditOperation, state: .unknown, ranAt: pending.ranAt
            ).historyEntry(hostUUID: hostUUID, id: pendingEntry.id)
            let auditSaved = update(finalEntry)
            reportUnknown(label: L("拉取镜像"), auditSaved: auditSaved)
        }
    }

    // MARK: - Destructive confirmation

    func requestDestructiveAction(_ action: DockerPendingAction) {
        pendingDestructiveAction = action
    }

    @discardableResult
    func confirmPendingAction(confirmation: String) async -> Bool {
        guard let action = pendingDestructiveAction else { return false }
        guard action.accepts(confirmation: confirmation) else {
            context.report(L("确认词不匹配，未执行 Docker 操作"))
            return false
        }
        pendingDestructiveAction = nil
        switch action {
        case let .removeContainer(container): await performConfirmed(.remove, on: container)
        case let .removeImage(image): await removeImageConfirmed(image)
        case let .removeVolume(volume): await removeVolumeConfirmed(name: volume.name)
        case let .removeNetwork(network): await removeNetworkConfirmed(name: network.name)
        case .pruneImages: await pruneImagesConfirmed()
        case let .systemPrune(options): await systemPruneConfirmed(options)
        }
        return true
    }

    // MARK: - Shared gate, audit and refresh

    private func execute(
        _ operation: DockerOperation,
        label: String,
        remote: (any SSHSession, Bool) async throws -> ExecResult
    ) async {
        guard begin(operation) else { return }
        defer { activeOperation = nil }
        do {
            let session = try await context.session()
            let result = try await remote(session, context.sudo)
            let state = DockerOperationResultState.known(exitCode: result.exitCode)
            let auditSaved = record(DockerAuditSummary(operation: operation.auditOperation, state: state))
            reportKnown(label: label, state: state, auditSaved: auditSaved)
            // 非零退出码仍是一个已知终态；Docker 可能已部分完成，刷新才不会留旧列表。
            await context.refresh(operation.refreshScope)
        } catch {
            let auditSaved = record(DockerAuditSummary(operation: operation.auditOperation, state: .unknown))
            // 连接中断、超时或 stream 没有终态时，远端实际状态无法推断，不能刷新覆盖当前视图。
            reportUnknown(label: label, auditSaved: auditSaved)
        }
    }

    private func begin(_ operation: DockerOperation) -> Bool {
        guard activeOperation == nil else {
            context.report(L("另一个 Docker 操作正在进行"))
            return false
        }
        activeOperation = operation
        return true
    }

    private func record(_ summary: DockerAuditSummary) -> Bool {
        do {
            try runHistory.record(summary.historyEntry(hostUUID: hostUUID))
            return true
        } catch {
            return false
        }
    }

    private func update(_ entry: RunHistoryEntry) -> Bool {
        do {
            try runHistory.update(entry)
            return true
        } catch {
            return false
        }
    }

    private func reportKnown(label: String, state: DockerOperationResultState, auditSaved: Bool) {
        let resultText: String
        if state.isSuccess {
            resultText = String(format: L("%@ 成功"), label)
        } else if let exitCode = state.exitCode {
            resultText = String(format: L("%@ 失败（退出码 %d）"), label, exitCode)
        } else {
            resultText = String(format: L("%@ 结果未知"), label)
        }
        context.report(auditSaved ? resultText : resultText + L("；审计未保存"))
    }

    private func reportUnknown(label: String, auditSaved: Bool) {
        let resultText = String(format: L("%@ 结果未知"), label)
        context.report(auditSaved ? resultText : resultText + L("；审计未保存"))
    }
}
