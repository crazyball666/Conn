import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 卷列表与详情。
@Observable
@MainActor
final class DockerVolumesModel {
    private(set) var items: [VolumeInfo] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// 无任何容器引用的卷名。直接用 Docker 的 dangling 语义——对卷而言
    /// 它的定义就是「没被引用」，与我们要表达的一致，不在客户端重新比对。
    private(set) var unusedNames: Set<String> = []

    private let context: DockerContext

    init(context: DockerContext) {
        self.context = context
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await load()
    }

    /// Docker 已探测为不可用时静默 no-op——与 `DockerImagesModel.load()` 同款守卫，
    /// 保持四类资源在「不可用」态下的行为一致。
    func load() async {
        guard context.isUsable else { return }
        do {
            let session = try await context.session()
            // 两条命令并行：徽标不该让列表多等一个往返
            async let list = DockerService.listVolumes(on: session, sudo: context.sudo)
            async let dangling = DockerService.danglingVolumeNames(on: session, sudo: context.sudo)
            items = try await list
            unusedNames = try await dangling
            error = nil
        } catch {
            self.error = error.friendlyDiagnosis
        }
        loaded = true
    }

    func detail(for volume: VolumeInfo) async -> VolumeDetail? {
        try? await DockerService.volumeDetail(
            name: volume.name, on: context.session(), sudo: context.sudo
        )
    }

    /// 引用该卷的容器。只在打开详情页时才跑。
    func containersUsing(_ volume: VolumeInfo) async -> [ContainerInfo] {
        (try? await DockerService.containersUsingVolume(
            name: volume.name, on: context.session(), sudo: context.sudo
        )) ?? []
    }
}
