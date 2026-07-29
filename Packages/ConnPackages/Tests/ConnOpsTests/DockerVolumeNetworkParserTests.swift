import Testing
@testable import ConnOps

@Suite("DockerParser — 卷与网络")
struct DockerVolumeNetworkParserTests {
    // swiftlint:disable line_length
    /// 取自 `docker volume ls --format '{{json .}}'` 的真实输出形状。
    /// 注意 Size 恒为 N/A——卷大小 docker volume ls 根本不给，只能靠 system df。
    static let volumeLines = """
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"com.docker.compose.project=web","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/web_assets/_data","Name":"web_assets","Scope":"local","Size":"N/A","Status":"N/A"}
    """
    // swiftlint:enable line_length

    @Test("解析卷列表")
    func parsesVolumes() {
        let volumes = DockerParser.parseVolumes(Self.volumeLines)
        #expect(volumes.count == 2)
        #expect(volumes[0].name == "pgdata")
        #expect(volumes[0].driver == "local")
        #expect(volumes[0].scope == "local")
        #expect(volumes[0].mountpoint == "/var/lib/docker/volumes/pgdata/_data")
        #expect(volumes[1].name == "web_assets")
    }

    /// docker 偶尔在 stdout 混入 warning 行，坏行必须跳过而不是整批失败。
    @Test("非 JSON 噪声行被跳过")
    func skipsNoiseLines() {
        let output = "WARNING: something\n" + Self.volumeLines + "\nnot json"
        #expect(DockerParser.parseVolumes(output).count == 2)
    }

    @Test("空输出得空数组，不崩")
    func emptyOutput() {
        #expect(DockerParser.parseVolumes("").isEmpty)
        #expect(DockerParser.parseNetworks("").isEmpty)
    }

    // swiftlint:disable line_length
    static let networkLines = """
    {"CreatedAt":"2026-01-02 03:04:05","Driver":"bridge","ID":"a1b2c3d4e5f6","IPv6":"false","Internal":"false","Labels":"","Name":"bridge","Scope":"local"}
    {"CreatedAt":"2026-02-03 04:05:06","Driver":"bridge","ID":"f6e5d4c3b2a1","IPv6":"false","Internal":"false","Labels":"","Name":"web_default","Scope":"local"}
    """
    // swiftlint:enable line_length

    @Test("解析网络列表")
    func parsesNetworks() {
        let networks = DockerParser.parseNetworks(Self.networkLines)
        #expect(networks.count == 2)
        #expect(networks[0].name == "bridge")
        #expect(networks[0].driver == "bridge")
        #expect(networks[0].scope == "local")
        #expect(networks[1].id == "f6e5d4c3b2a1")
    }

    /// bridge / host / none 是 Docker 预置的，永远删不掉。
    /// 给它们打「未使用」徽标只会制造噪声，所以模型自己要能认出来。
    @Test("预置网络被识别")
    func predefinedNetworks() {
        let networks = DockerParser.parseNetworks(Self.networkLines)
        #expect(networks[0].isPredefined, "bridge 是预置网络")
        #expect(!networks[1].isPredefined, "web_default 不是")
        #expect(NetworkInfo(id: "x", name: "host", driver: "host", scope: "local").isPredefined)
        #expect(NetworkInfo(id: "x", name: "none", driver: "null", scope: "local").isPredefined)
    }

    // Labels/Options 各给两个键，且故意按非字典序书写（先 com.example.owner 后
    // com.docker.compose.project；先 type 后 device）——单键数组排不排序结果一样，
    // 只有真的执行了 keyValueList 里的 .sorted() 才能得到断言里的字典序结果。
    // swiftlint:disable line_length
    static let volumeInspectJSON = """
    [{"CreatedAt":"2026-01-02T03:04:05Z","Driver":"local","Labels":{"com.example.owner":"ops","com.docker.compose.project":"web"},"Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Options":{"type":"nfs","device":":/data"},"Scope":"local"}]
    """
    // swiftlint:enable line_length

    @Test("解析卷详情")
    func parsesVolumeInspect() throws {
        let detail = try #require(DockerParser.parseVolumeInspect(Self.volumeInspectJSON))
        #expect(detail.name == "pgdata")
        #expect(detail.driver == "local")
        #expect(detail.mountpoint == "/var/lib/docker/volumes/pgdata/_data")
        #expect(detail.createdAt == "2026-01-02 03:04")
        #expect(detail.labels == ["com.docker.compose.project=web", "com.example.owner=ops"])
        #expect(detail.options == ["device=:/data", "type=nfs"])
    }

    @Test("坏的卷详情返回 nil 而不是崩")
    func badVolumeInspect() {
        #expect(DockerParser.parseVolumeInspect("") == nil)
        #expect(DockerParser.parseVolumeInspect("[]") == nil)
        #expect(DockerParser.parseVolumeInspect("not json") == nil)
    }

    static let networkInspectJSON = """
    [{"Name":"web_default","Id":"f6e5d4c3b2a1c0d9e8f7a6b5c4d3e2f1","Scope":"local","Driver":"bridge","Internal":false,
      "IPAM":{"Config":[{"Subnet":"172.20.0.0/16","Gateway":"172.20.0.1"}]},
      "Containers":{"aaa111":{"Name":"web-nginx","IPv4Address":"172.20.0.2/16"},
                    "bbb222":{"Name":"pg-main","IPv4Address":"172.20.0.3/16"}}}]
    """

    @Test("解析网络详情，含接入容器")
    func parsesNetworkInspect() throws {
        let detail = try #require(DockerParser.parseNetworkInspect(Self.networkInspectJSON))
        // 网络详情的 id 不截断（不同于容器 inspect 的 12 位短 id），要与夹具里的完整长串一致
        #expect(detail.id == "f6e5d4c3b2a1c0d9e8f7a6b5c4d3e2f1")
        #expect(detail.name == "web_default")
        #expect(detail.driver == "bridge")
        #expect(detail.scope == "local")
        #expect(detail.subnet == "172.20.0.0/16")
        #expect(detail.gateway == "172.20.0.1")
        #expect(!detail.isInternal)
        // 顺序按容器名排序，保证 UI 稳定——JSON 字典本身无序
        #expect(detail.attachedContainers.map(\.name) == ["pg-main", "web-nginx"])
        #expect(detail.attachedContainers[1].ipv4 == "172.20.0.2/16")
    }

    /// 没有容器接入时不能崩，也不能返回 nil——网络本身还在。
    @Test("无接入容器的网络仍能解析")
    func networkWithoutContainers() throws {
        let json = """
        [{"Name":"isolated","Id":"abc","Scope":"local","Driver":"bridge","Internal":true,
          "IPAM":{"Config":[]},"Containers":{}}]
        """
        let detail = try #require(DockerParser.parseNetworkInspect(json))
        #expect(detail.attachedContainers.isEmpty)
        #expect(detail.isInternal)
        #expect(detail.subnet == nil)
    }

    @Test("dangling 过滤输出解析成名字集合")
    func parsesNameList() {
        #expect(DockerParser.parseNameList("pgdata\nweb_assets\n") == ["pgdata", "web_assets"])
        #expect(DockerParser.parseNameList("").isEmpty)
        #expect(DockerParser.parseNameList("  \n\n") .isEmpty)
    }
}

@Suite("DockerCommand — 卷与网络")
struct DockerVolumeNetworkCommandTests {
    @Test("卷命令")
    func volumeCommands() {
        #expect(DockerCommand.volumes(sudo: false) == "docker volume ls --format '{{json .}}'")
        #expect(DockerCommand.volumes(sudo: true) == "sudo -n docker volume ls --format '{{json .}}'")
        #expect(DockerCommand.danglingVolumes(sudo: false) == "docker volume ls --filter dangling=true -q")
        #expect(DockerCommand.volumeInspect(name: "pgdata", sudo: false) == "docker volume inspect pgdata")
    }

    @Test("网络命令")
    func networkCommands() {
        #expect(DockerCommand.networks(sudo: false) == "docker network ls --format '{{json .}}'")
        #expect(DockerCommand.danglingNetworks(sudo: false) == "docker network ls --filter dangling=true --format '{{.Name}}'")
        #expect(DockerCommand.networkInspect(name: "web_default", sudo: false) == "docker network inspect web_default")
    }
}
