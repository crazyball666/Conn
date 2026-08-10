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
    var busyImageID: String? { operations.activeImageID }
    var pendingRemoval: ImageInfo? {
        get {
            guard case let .removeImage(image)? = operations.pendingDestructiveAction else { return nil }
            return image
        }
        set {
            if let newValue {
                operations.requestDestructiveAction(.removeImage(newValue))
            } else if case .removeImage = operations.pendingDestructiveAction {
                operations.pendingDestructiveAction = nil
            }
        }
    }
    /// 没有任何容器引用的镜像 id。由容器列表反查——不能用 docker 的 dangling，
    /// 那是「无 tag」，与「没被引用」是两码事。
    private(set) var unusedIDs: Set<String> = []

    private let context: DockerContext
    private let operations: DockerOperationsModel

    init(context: DockerContext, operations: DockerOperationsModel) {
        self.context = context
        self.operations = operations
    }

    /// 仅首次加载（镜像分段出现时调用）。
    func loadIfNeeded() async {
        guard !loaded else { return }
        await load()
    }

    /// Docker 已探测为不可用时静默 no-op——不设置 `loaded`，也不清空既有列表/错误态，
    /// 与重构前 `loadImages()` 的这道守卫逐字一致。
    func load() async {
        guard context.isUsable else { return }
        do {
            items = try await DockerService.listImages(on: context.session(), runtime: context.runtime)
            error = nil
        } catch {
            self.error = error.friendlyDiagnosis
        }
        loaded = true
    }

    /// 用容器列表刷新「未使用」判定。容器段本来就要拉 ps -a，不额外跑命令。
    func refreshUsage(containers: [ContainerInfo]) {
        unusedIDs = ImageUsage.unusedImageIDs(images: items, containers: containers)
    }

    func detail(for image: ImageInfo) async throws -> ImageDetail {
        try await DockerService.imageDetail(
            reference: image.reference, on: context.session(), runtime: context.runtime
        )
    }

    func history(for image: ImageInfo) async throws -> [ImageLayer] {
        try await DockerService.imageHistory(
            reference: image.reference, on: context.session(), runtime: context.runtime
        )
    }

    func requestRemoval(_ image: ImageInfo) {
        operations.requestDestructiveAction(.removeImage(image))
    }

    func prune() async {
        operations.requestDestructiveAction(.pruneImages)
    }
}
