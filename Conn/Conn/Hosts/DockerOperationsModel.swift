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
    private(set) var pullPresentation: DockerPullPresentation?

    private let context: DockerContext
    private let audit: DockerAuditWriter
    private let isProduction: Bool

    init(
        context: DockerContext,
        hostUUID: String,
        runHistory: any RunHistoryRepository,
        isProduction: Bool = false
    ) {
        self.context = context
        audit = DockerAuditWriter(hostUUID: hostUUID, repository: runHistory)
        self.isProduction = isProduction
    }

    var isBusy: Bool { activeOperation != nil }
    var isWriteAvailable: Bool { context.isUsable && context.runtime != nil && !isBusy }
    var activeOperationDescription: String? {
        guard let activeOperation else { return nil }
        return "\(activeOperation.auditOperation.historyLabel) · \(L("执行中…"))"
    }
    var activeContainerID: String? { activeOperation?.activeContainerID }
    var activeImageID: String? { activeOperation?.activeImageID }
    var isPullActive: Bool {
        guard case .pullImage? = activeOperation else { return false }
        return true
    }
    var canDismissPull: Bool { pullPresentation?.result != nil }

    // MARK: - Existing write entry points

    @discardableResult
    func perform(_ action: ContainerAction, on container: ContainerInfo) async -> DockerOperationOutcome? {
        guard !action.isDestructive else {
            requestDestructiveAction(.removeContainer(container))
            return nil
        }
        if isProduction, action == .stop || action == .restart {
            requestDestructiveAction(.container(action: action, container: container))
            return nil
        }
        return await performConfirmed(action, on: container)
    }

    private func performConfirmed(
        _ action: ContainerAction,
        on container: ContainerInfo
    ) async -> DockerOperationOutcome {
        let operation = DockerOperation.container(action: action, targetID: container.id)
        return await execute(operation, label: String(format: L("%@容器"), action.label)) { session, runtime in
            try await DockerService.perform(action, id: container.id, on: session, runtime: runtime)
        }
    }

    private func removeImageConfirmed(_ image: ImageInfo) async -> DockerOperationOutcome {
        await execute(.removeImage(targetID: image.id), label: L("删除镜像")) { session, runtime in
            try await DockerService.removeImage(reference: image.reference, on: session, runtime: runtime)
        }
    }

    private func pruneImagesConfirmed() async -> DockerOperationOutcome {
        await execute(.pruneImages, label: L("清理悬空镜像")) { session, runtime in
            try await DockerService.pruneImages(on: session, runtime: runtime)
        }
    }

    // MARK: - Phase 2 write entry points

    @discardableResult
    func runContainer(_ draft: DockerRunDraft) async -> DockerOperationOutcome {
        guard draft.validate().isEmpty else {
            let message = L("容器配置无效，未执行 Docker 操作")
            context.report(message)
            return .rejected(message: message)
        }
        return await execute(.runContainer, label: L("创建容器")) { session, runtime in
            try await DockerService.runContainer(draft, on: session, runtime: runtime)
        }
    }

    @discardableResult
    func createVolume(_ draft: DockerVolumeDraft) async -> DockerOperationOutcome {
        guard draft.validate().isEmpty else {
            let message = L("卷配置无效，未执行 Docker 操作")
            context.report(message)
            return .rejected(message: message)
        }
        return await execute(.createVolume, label: L("创建卷")) { session, runtime in
            try await DockerService.createVolume(draft, on: session, runtime: runtime)
        }
    }

    private func removeVolumeConfirmed(name: String) async -> DockerOperationOutcome {
        await execute(.removeVolume, label: L("删除卷")) { session, runtime in
            try await DockerService.removeVolume(name: name, on: session, runtime: runtime)
        }
    }

    @discardableResult
    func createNetwork(_ draft: DockerNetworkDraft) async -> DockerOperationOutcome {
        guard draft.validate().isEmpty else {
            let message = L("网络配置无效，未执行 Docker 操作")
            context.report(message)
            return .rejected(message: message)
        }
        return await execute(.createNetwork, label: L("创建网络")) { session, runtime in
            try await DockerService.createNetwork(draft, on: session, runtime: runtime)
        }
    }

    private func removeNetworkConfirmed(name: String) async -> DockerOperationOutcome {
        await execute(.removeNetwork, label: L("删除网络")) { session, runtime in
            try await DockerService.removeNetwork(name: name, on: session, runtime: runtime)
        }
    }

    private func systemPruneConfirmed(_ options: DockerSystemPruneOptions) async -> DockerOperationOutcome {
        await execute(.systemPrune, label: L("清理 Docker 资源")) { session, runtime in
            try await DockerService.systemPrune(options, on: session, runtime: runtime)
        }
    }

    // MARK: - Phase 3 Compose write entry points

    @discardableResult
    func composeUp(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect
    ) async -> DockerOperationOutcome {
        if isProduction {
            requestDestructiveAction(.composeUp(project: project, dialect: dialect))
            return .rejected(message: L("确认 Docker 操作"))
        }
        return await composeUpConfirmed(project, dialect: dialect)
    }

    private func composeUpConfirmed(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect
    ) async -> DockerOperationOutcome {
        await execute(.composeUp(projectName: project.name), label: L("启动 Compose 项目")) { session, runtime in
            try await DockerService.composeUp(
                project, dialect: dialect, on: session, runtime: runtime
            )
        }
    }

    @discardableResult
    func composeRestart(
        _ project: DockerComposeProject,
        service: String? = nil,
        dialect: DockerComposeDialect
    ) async -> DockerOperationOutcome {
        if isProduction {
            requestDestructiveAction(
                .composeRestart(project: project, service: service, dialect: dialect)
            )
            return .rejected(message: L("确认 Docker 操作"))
        }
        return await composeRestartConfirmed(
            project,
            service: service,
            dialect: dialect
        )
    }

    private func composeRestartConfirmed(
        _ project: DockerComposeProject,
        service: String? = nil,
        dialect: DockerComposeDialect
    ) async -> DockerOperationOutcome {
        await execute(
            .composeRestart(projectName: project.name, serviceName: service),
            label: service == nil ? L("重启 Compose 项目") : L("重启 Compose 服务")
        ) { session, runtime in
            try await DockerService.composeRestart(
                project, service: service, dialect: dialect, on: session, runtime: runtime
            )
        }
    }

    private func composeDownConfirmed(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect
    ) async -> DockerOperationOutcome {
        await execute(
            .composeDown(projectName: project.name),
            label: L("停止并移除 Compose 项目")
        ) { session, runtime in
            context.preserveComposeProject(project)
            return try await DockerService.composeDown(
                project, dialect: dialect, on: session, runtime: runtime
            )
        }
    }

    /// 拉取是唯一流式写操作：远端启动前先同步写 pending；若本地审计不可用，就宁可不发
    /// 命令，避免制造无法追踪的长任务。
    /// 从普通 sheet 提交拉取。先同步建立 presentation，再启动远端工作，让顶层
    /// `fullScreenCover(item:)` 不会有一帧可被手势关掉的空窗。
    func startPull(reference: String) {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            context.report(L("镜像引用不能为空"))
            return
        }
        guard begin(.pullImage) == nil else { return }
        pullPresentation = DockerPullPresentation()
        Task { [weak self] in
            await self?.performPull(reference: reference, onChunk: { _ in })
        }
    }

    /// 测试和非 UI 调用使用的 await 入口；和 `startPull` 复用同一终态与审计语义。
    func pullImage(reference: String, onChunk: @escaping (String) -> Void) async {
        guard begin(.pullImage) == nil else { return }
        pullPresentation = DockerPullPresentation()
        await performPull(reference: reference, onChunk: onChunk)
    }

    /// 只有已经拿到 known 或 unknown 终态才可关闭。外部 binding 的 nil 写入也经这道
    /// 门，避免 interactive dismiss 或 SwiftUI route 重置中断活动中的远端 pull。
    func dismissPullProgress() {
        guard canDismissPull else { return }
        pullPresentation = nil
    }

    private func performPull(reference: String, onChunk: @escaping (String) -> Void) async {
        let operation = DockerOperation.pullImage
        defer { activeOperation = nil }

        guard let pendingEntry = audit.recordPending(for: operation) else {
            context.report(L("无法保存拉取审计，未开始拉取"))
            setPullResult(.unknown)
            return
        }

        do {
            let session = try await context.session()
            let runtime = try context.requireRuntime()
            let stream = try await DockerService.pullImage(
                reference: reference,
                on: session,
                runtime: runtime
            )
            // 输出流故障并不必然代表远端没有终态；仍等待 result()，只要拿到最终
            // ExecResult 就按 known 处理。没有 result 才是 unknown。
            do {
                for try await chunk in stream.output {
                    // SSH 输出可能含截断 UTF-8；与 ExecResult 一样保留可读部分。
                    // swiftlint:disable:next optional_data_string_conversion
                    let text = String(decoding: chunk, as: UTF8.self)
                    appendPullLog(text)
                    onChunk(text)
                }
            } catch {
                // result() below remains the authority for result certainty.
            }
            let result = try await stream.result()
            let state = DockerOperationResultState.known(exitCode: result.exitCode)
            let outcome = DockerOperationOutcome(result: result)
            let finalEntry = DockerAuditSummary(
                operation: operation.auditOperation,
                state: state,
                ranAt: pendingEntry.ranAt
            ).historyEntry(hostUUID: audit.hostUUID, id: pendingEntry.id)
            let auditSaved = audit.update(finalEntry)
            context.report(DockerOperationFeedback.message(
                for: outcome, label: L("拉取镜像"), auditSaved: auditSaved
            ))
            setPullResult(state)
            await context.refresh(operation.refreshScope)
        } catch {
            let finalEntry = DockerAuditSummary(
                operation: operation.auditOperation,
                state: .unknown,
                ranAt: pendingEntry.ranAt
            ).historyEntry(hostUUID: audit.hostUUID, id: pendingEntry.id)
            let auditSaved = audit.update(finalEntry)
            context.report(DockerOperationFeedback.message(
                for: .unknown(remoteMessage: error.friendlyDiagnosis),
                label: L("拉取镜像"),
                auditSaved: auditSaved
            ))
            setPullResult(.unknown)
        }
    }

    // MARK: - Destructive confirmation

    func requestDestructiveAction(_ action: DockerPendingAction) {
        guard isWriteAvailable else { return }
        pendingDestructiveAction = action
    }

    func cancelPendingAction() {
        pendingDestructiveAction = nil
    }

    func canConfirmPendingAction(input: String) -> Bool {
        pendingDestructiveAction?.accepts(confirmation: input) == true
    }

    @discardableResult
    func confirmPendingAction(confirmation: String) async -> Bool { // swiftlint:disable:this cyclomatic_complexity
        guard let action = pendingDestructiveAction else { return false }
        guard action.accepts(confirmation: confirmation) else {
            context.report(L("确认词不匹配，未执行 Docker 操作"))
            return false
        }
        pendingDestructiveAction = nil
        switch action {
        case let .container(action, container):
            _ = await performConfirmed(action, on: container)
        case let .removeContainer(container):
            _ = await performConfirmed(.remove, on: container)
        case let .removeImage(image):
            _ = await removeImageConfirmed(image)
        case let .removeVolume(volume):
            _ = await removeVolumeConfirmed(name: volume.name)
        case let .removeNetwork(network):
            _ = await removeNetworkConfirmed(name: network.name)
        case .pruneImages:
            _ = await pruneImagesConfirmed()
        case let .systemPrune(options):
            _ = await systemPruneConfirmed(options)
        case let .composeUp(project, dialect):
            _ = await composeUpConfirmed(project, dialect: dialect)
        case let .composeDown(project, dialect):
            _ = await composeDownConfirmed(project, dialect: dialect)
        case let .composeRestart(project, service, dialect):
            _ = await composeRestartConfirmed(project, service: service, dialect: dialect)
        }
        return true
    }

    // MARK: - Shared gate, audit and refresh

    private func execute(
        _ operation: DockerOperation,
        label: String,
        remote: (any SSHSession, DockerRuntimeContext) async throws -> ExecResult
    ) async -> DockerOperationOutcome {
        if let rejection = begin(operation) { return rejection }
        defer { activeOperation = nil }
        guard let pendingEntry = audit.recordPending(for: operation) else {
            let message = L("无法保存 Docker 操作审计，未执行远程命令")
            context.report(message)
            return .unknown(remoteMessage: message)
        }
        do {
            let session = try await context.session()
            let runtime = try context.requireRuntime()
            let result = try await remote(session, runtime)
            let state = DockerOperationResultState.known(exitCode: result.exitCode)
            let outcome = DockerOperationOutcome(result: result)
            let auditSaved = audit.update(
                DockerAuditSummary(
                    operation: operation.auditOperation,
                    state: state,
                    ranAt: pendingEntry.ranAt
                ).historyEntry(hostUUID: audit.hostUUID, id: pendingEntry.id)
            )
            context.report(DockerOperationFeedback.message(
                for: outcome, label: label, auditSaved: auditSaved
            ))
            // 非零退出码仍是一个已知终态；Docker 可能已部分完成，刷新才不会留旧列表。
            await context.refresh(operation.refreshScope)
            return outcome
        } catch {
            let auditSaved = audit.update(
                DockerAuditSummary(
                    operation: operation.auditOperation,
                    state: .unknown,
                    ranAt: pendingEntry.ranAt
                ).historyEntry(hostUUID: audit.hostUUID, id: pendingEntry.id)
            )
            // 连接中断、超时或 stream 没有终态时，远端实际状态无法推断，不能刷新覆盖当前视图。
            let outcome = DockerOperationOutcome.unknown(remoteMessage: error.friendlyDiagnosis)
            context.report(DockerOperationFeedback.message(
                for: outcome, label: label, auditSaved: auditSaved
            ))
            return outcome
        }
    }

    private func begin(_ operation: DockerOperation) -> DockerOperationOutcome? {
        guard context.isUsable, context.runtime != nil else {
            let message = L("Docker 当前不可用")
            context.report(message)
            return .rejected(message: message)
        }
        guard activeOperation == nil else {
            let message = L("另一个 Docker 操作正在进行")
            context.report(message)
            return .rejected(message: message)
        }
        activeOperation = operation
        return nil
    }

    private func appendPullLog(_ text: String) {
        guard var presentation = pullPresentation else { return }
        presentation.logs += text
        pullPresentation = presentation
    }

    private func setPullResult(_ result: DockerOperationResultState) {
        guard var presentation = pullPresentation else { return }
        presentation.result = result
        pullPresentation = presentation
    }

}
