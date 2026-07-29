import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 镜像列表与写操作。
@Observable
@MainActor
final class DockerImagesModel {
    private(set) var items: [ImageInfo] = []
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var busyImageID: String?
    var pendingRemoval: ImageInfo?

    private let context: DockerContext

    init(context: DockerContext) {
        self.context = context
    }

    /// 仅首次加载（镜像分段出现时调用）。
    func loadIfNeeded() async {
        guard !loaded else { return }
        await load()
    }

    func load() async {
        do {
            items = try await DockerService.listImages(on: context.session(), sudo: context.sudo)
            error = nil
        } catch {
            self.error = error.friendlyDiagnosis
        }
        loaded = true
    }

    func requestRemoval(_ image: ImageInfo) {
        pendingRemoval = image
    }

    func confirmRemoval() async {
        guard let image = pendingRemoval else { return }
        pendingRemoval = nil
        busyImageID = image.id
        defer { busyImageID = nil }
        await run(String(format: L("删除镜像 %@"), image.displayName)) { session, sudo in
            try await DockerService.removeImage(reference: image.reference, on: session, sudo: sudo)
        }
    }

    func prune() async {
        await run(L("清理悬空镜像")) { session, sudo in
            try await DockerService.pruneImages(on: session, sudo: sudo)
        }
    }

    /// 写操作统一执行 + 审计 + 刷新 + 结果提示。
    private func run(
        _ label: String,
        _ operation: (any SSHSession, Bool) async throws -> ExecResult
    ) async {
        do {
            let result = try await operation(context.session(), context.sudo)
            context.audit(label, result)
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            context.report(result.isSuccess
                ? String(format: L("%@ 成功"), label)
                : String(format: L("%@ 失败：%@"), label, detail))
            await load()
        } catch {
            context.report(String(format: L("%@ 失败：%@"), label, error.friendlyDiagnosis))
        }
    }
}
