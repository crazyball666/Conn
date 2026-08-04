import ConnSSH
import Testing
@testable import ConnOps

@Suite("DockerService — 卷 / 网络 / 镜像详情取数", .serialized)
struct DockerServiceResourceTests {
    private func session(_ responses: [String: String]) async throws -> any SSHSession {
        let mapped = responses.mapValues { MockSSHTransport.CommandResponse(stdout: $0) }
        return try await session(mapped)
    }

    private func session(
        _ responses: [String: MockSSHTransport.CommandResponse]
    ) async throws -> any SSHSession {
        let transport = MockSSHTransport(behavior: .init(commandResponses: responses))
        return try await transport.connect(
            SSHEndpoint(host: "h", port: 22), username: "root", auth: .password(""), hostKeyPolicy: .tofu
        )
    }

    @Test("列卷")
    func listsVolumes() async throws {
        let json = """
        {"Driver":"local","Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Scope":"local"}
        """
        let session = try await session([DockerCommand.volumes(sudo: false): json])
        let volumes = try await DockerService.listVolumes(on: session, sudo: false)
        #expect(volumes.map(\.name) == ["pgdata"])
    }

    @Test("dangling 卷名集合")
    func danglingVolumes() async throws {
        let session = try await session([DockerCommand.danglingVolumes(sudo: false): "old_cache\ntmp\n"])
        let names = try await DockerService.danglingVolumeNames(on: session, sudo: false)
        #expect(names == ["old_cache", "tmp"])
    }

    @Test("列网络")
    func listsNetworks() async throws {
        let json = """
        {"CreatedAt":"x","Driver":"bridge","ID":"abc","Name":"bridge","Scope":"local"}
        """
        let session = try await session([DockerCommand.networks(sudo: false): json])
        #expect(try await DockerService.listNetworks(on: session, sudo: false).map(\.name) == ["bridge"])
    }

    @Test("网络详情")
    func networkDetail() async throws {
        let json = """
        [{"Name":"web","Id":"abc","Driver":"bridge","Scope":"local","Internal":false,
          "IPAM":{"Config":[{"Subnet":"172.20.0.0/16","Gateway":"172.20.0.1"}]},
          "Containers":{"c1":{"Name":"web-1","IPv4Address":"172.20.0.2/16"}}}]
        """
        let session = try await session([DockerCommand.networkInspect(name: "web", sudo: false): json])
        let detail = try await DockerService.networkDetail(name: "web", on: session, sudo: false)
        #expect(detail.attachedContainers.map(\.name) == ["web-1"])
    }

    @Test("镜像详情与层历史")
    func imageDetailAndHistory() async throws {
        let inspect = """
        [{"Id":"sha256:a1b2c3d4e5f6","RepoTags":["nginx:1.25"],"Created":"2026-01-02T03:04:05Z",
          "Size":1000,"Architecture":"amd64","Os":"linux","Config":{"Cmd":["nginx"]}}]
        """
        let history = """
        {"CreatedBy":"apt-get install","CreatedSince":"2 days ago","ID":"<missing>","Size":"58MB"}
        """
        let session = try await session([
            DockerCommand.imageInspect(reference: "nginx:1.25", sudo: false): inspect,
            DockerCommand.imageHistory(reference: "nginx:1.25", sudo: false): history
        ])
        let detail = try await DockerService.imageDetail(reference: "nginx:1.25", on: session, sudo: false)
        #expect(detail.tags == ["nginx:1.25"])
        let layers = try await DockerService.imageHistory(reference: "nginx:1.25", on: session, sudo: false)
        #expect(layers.count == 1)
        #expect(layers[0].size == "58MB")
    }

    /// 老 docker 吐表格 → 服务层必须给 nil，而不是抛错。
    /// 抛错会让调用方以为整页坏了，而这只是个锦上添花的字段。
    @Test("磁盘占用格式不支持时返回 nil 而不抛错")
    func diskUsageDegrades() async throws {
        let session = try await session([DockerCommand.diskUsage(sudo: false): "TYPE  TOTAL  SIZE"])
        #expect(try await DockerService.diskUsage(on: session, sudo: false) == nil)
    }

    /// 正常路径：断言具体字段值，而不是只判非 nil——否则把函数体换成
    /// 返回一个空壳 `VolumeDetail` 仍然会让测试通过，等于没测。
    @Test("卷详情")
    func volumeDetail() async throws {
        let json = """
        [{"CreatedAt":"2026-01-02T03:04:05Z","Driver":"local","Labels":{"com.example.owner":"ops"},
          "Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Options":{"type":"nfs"},"Scope":"local"}]
        """
        let session = try await session([DockerCommand.volumeInspect(name: "pgdata", sudo: false): json])
        let detail = try await DockerService.volumeDetail(name: "pgdata", on: session, sudo: false)
        #expect(detail.name == "pgdata")
        #expect(detail.driver == "local")
        #expect(detail.mountpoint == "/var/lib/docker/volumes/pgdata/_data")
        #expect(detail.createdAt == "2026-01-02 03:04")
        #expect(detail.labels == ["com.example.owner=ops"])
        #expect(detail.options == ["type=nfs"])
    }

    @Test("dangling 网络名集合")
    func danglingNetworks() async throws {
        let session = try await session([DockerCommand.danglingNetworks(sudo: false): "old_net\nweb_default\n"])
        let names = try await DockerService.danglingNetworkNames(on: session, sudo: false)
        #expect(names == ["old_net", "web_default"])
    }

    /// 正常路径：格式正确的 `docker system df -v --format json` 要能解析出
    /// 有内容的 `DockerDiskUsage`。`diskUsageDegrades` 只覆盖了「格式不支持返回 nil」
    /// 这条降级路径，两条合起来才把 `diskUsage` 的行为钉住。
    @Test("磁盘占用格式支持时解析出具体占用")
    func diskUsageParsesRealData() async throws {
        let json = """
        {"Images":[{"ID":"sha256:a1b2c3d4e5f6a7b8","Repository":"nginx","Tag":"1.25","Size":"142MB"}],
         "Volumes":[{"Name":"pgdata","Size":"1.2GB","Links":1}],"Containers":[],"BuildCache":[]}
        """
        let session = try await session([DockerCommand.diskUsage(sudo: false): json])
        let usage = try #require(try await DockerService.diskUsage(on: session, sudo: false))
        // 镜像索引用 12 位短 ID：system df 给带 sha256: 前缀的长 ID，解析器会归一化。
        #expect(usage.imageSize("a1b2c3d4e5f6") == "142MB")
        #expect(usage.volumeSize("pgdata") == "1.2GB")
    }

    @Test("反查引用某卷的容器")
    func containersUsingVolume() async throws {
        let json = """
        {"ID":"c1","Image":"pg:16","Names":"pg-main","State":"running","Status":"Up 2 days","Ports":""}
        """
        let session = try await session([
            DockerCommand.containersUsingVolume(name: "pgdata", sudo: false): json
        ])
        let hits = try await DockerService.containersUsingVolume(name: "pgdata", on: session, sudo: false)
        #expect(hits.map(\.name) == ["pg-main"])
    }

    @Test("详情命令失败时保留远端错误")
    func detailCommandFailureIncludesRemoteMessage() async throws {
        let command = DockerCommand.networkInspect(name: "missing", sudo: false)
        let session = try await session([
            command: .init(stderr: "Error: No such network: missing", exitCode: 1)
        ])

        await #expect(throws: DockerQueryError.commandFailed(
            exitCode: 1,
            message: "Error: No such network: missing"
        )) {
            try await DockerService.networkDetail(name: "missing", on: session, sudo: false)
        }
    }

    @Test("详情响应无法解析时抛错")
    func invalidDetailResponseThrows() async throws {
        let session = try await session([
            DockerCommand.imageInspect(reference: "bad", sudo: false): "not-json"
        ])

        await #expect(throws: DockerQueryError.invalidResponse) {
            try await DockerService.imageDetail(reference: "bad", on: session, sudo: false)
        }
    }

    @Test("资源列表命令非零退出不能伪装成空列表")
    func resourceListFailureThrows() async throws {
        let command = DockerCommand.networks(sudo: false)
        let session = try await session([
            command: .init(stderr: "permission denied", exitCode: 1)
        ])

        await #expect(throws: DockerQueryError.commandFailed(
            exitCode: 1,
            message: "permission denied"
        )) {
            try await DockerService.listNetworks(on: session, sudo: false)
        }
    }

    @Test("容器主列表失败不能被 stats 输出掩盖")
    func containerListFailureThrows() async throws {
        let session = try await session([
            DockerCommand.list(sudo: false): .init(
                stderr: "Cannot connect to the Docker daemon",
                exitCode: 1
            ),
            DockerCommand.stats(sudo: false): .init(stdout: "")
        ])

        await #expect(throws: DockerQueryError.commandFailed(
            exitCode: 1,
            message: "Cannot connect to the Docker daemon"
        )) {
            try await DockerService.list(on: session, sudo: false)
        }
    }

    @Test("详情关联子查询失败不能伪装成没有引用或没有历史")
    func relatedQueryFailuresThrow() async throws {
        let volumeCommand = DockerCommand.containersUsingVolume(name: "data", sudo: false)
        let historyCommand = DockerCommand.imageHistory(reference: "app:1", sudo: false)
        let session = try await session([
            volumeCommand: .init(stderr: "volume lookup failed", exitCode: 1),
            historyCommand: .init(stderr: "history lookup failed", exitCode: 1)
        ])

        await #expect(throws: DockerQueryError.commandFailed(
            exitCode: 1,
            message: "volume lookup failed"
        )) {
            try await DockerService.containersUsingVolume(
                name: "data",
                on: session,
                sudo: false
            )
        }
        await #expect(throws: DockerQueryError.commandFailed(
            exitCode: 1,
            message: "history lookup failed"
        )) {
            try await DockerService.imageHistory(
                reference: "app:1",
                on: session,
                sudo: false
            )
        }
    }
}
