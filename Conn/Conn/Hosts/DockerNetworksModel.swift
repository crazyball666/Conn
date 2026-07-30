import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 网络列表与详情。
@Observable
@MainActor
final class DockerNetworksModel {
    private(set) var items: [NetworkInfo] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// 无容器接入的网络名，**已滤掉预置的 bridge / host / none**——
    /// 它们永远删不掉，打徽标只是噪声。
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
            async let list = DockerService.listNetworks(on: session, sudo: context.sudo)
            async let dangling = DockerService.danglingNetworkNames(on: session, sudo: context.sudo)
            let networks = try await list
            let danglingNames = try await dangling
            items = networks
            let predefined = Set(networks.filter(\.isPredefined).map(\.name))
            unusedNames = danglingNames.subtracting(predefined)
            error = nil
        } catch {
            self.error = error.friendlyDiagnosis
        }
        loaded = true
    }

    /// 网络详情。接入容器由 inspect 直接给出，无需额外命令。
    func detail(for network: NetworkInfo) async -> NetworkDetail? {
        try? await DockerService.networkDetail(
            name: network.name, on: context.session(), sudo: context.sudo
        )
    }
}
