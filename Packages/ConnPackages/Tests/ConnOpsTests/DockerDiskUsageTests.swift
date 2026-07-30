import Testing
@testable import ConnOps

@Suite("DockerParser — 磁盘占用")
struct DockerDiskUsageTests {
    /// `docker system df -v --format '{{json .}}'`（Docker 24+）。
    static let json = """
    {"Images":[{"ID":"sha256:a1b2c3d4e5f6a7b8","Repository":"nginx","Tag":"1.25","Size":"142MB"},
               {"ID":"sha256:bbb444555666","Repository":"redis","Tag":"7","Size":"117MB"}],
     "Volumes":[{"Name":"pgdata","Size":"1.2GB","Links":1},
                {"Name":"web_assets","Size":"48MB","Links":0}],
     "Containers":[],"BuildCache":[]}
    """

    @Test("按名索引卷占用")
    func indexesVolumeSizes() throws {
        let usage = try #require(DockerParser.parseDiskUsage(Self.json))
        #expect(usage.volumeSize("pgdata") == "1.2GB")
        #expect(usage.volumeSize("web_assets") == "48MB")
        #expect(usage.volumeSize("不存在") == nil)
    }

    /// 索引键用 12 位短 ID：`docker images` 给的是短 ID，
    /// 而 `system df` 给的是带 sha256: 前缀的长 ID，不归一化就永远查不到。
    @Test("镜像占用按短 ID 索引")
    func indexesImageSizesByShortID() throws {
        let usage = try #require(DockerParser.parseDiskUsage(Self.json))
        #expect(usage.imageSize("a1b2c3d4e5f6") == "142MB")
        #expect(usage.imageSize("bbb444555666") == "117MB")
    }

    /// 老版本 docker 不支持 --format json，会吐出表格文本。
    /// 这时必须返回 nil 让上层显示「—」，而不是崩或者给出错误数字。
    @Test("非 JSON 输出返回 nil 而不是崩")
    func tableOutputReturnsNil() {
        let table = """
        TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
        Images          28        9         4.2GB     3.1GB (73%)
        """
        #expect(DockerParser.parseDiskUsage(table) == nil)
    }

    /// 补充用例：上面那条表格文本其实不需要 `guard hasPrefix("{")` 也能返回 nil——
    /// `JSONDecoder` 对着结构体形态的 DTO，本来就会拒绝任何非 JSON 对象的输入，
    /// 单删掉这行 guard 并不会让 `tableOutputReturnsNil` 变红（已用变异验证确认）。
    /// 真正能让这道判据产生行为差异的输入是带 BOM 的合法 JSON：BOM 不在
    /// `trimmingCharacters(.whitespacesAndNewlines)` 的范围内所以 `hasPrefix("{")`
    /// 为假，但 `JSONDecoder` 本身会容忍 BOM 并解码成功——这是本函数里唯一会被
    /// guard 拦下、否则会被解码出「看似正常」结果的输入，因此拿它来钉住这道判据。
    @Test("BOM 前缀的合法 JSON 仍返回 nil（这才是 hasPrefix 真正把关的输入）")
    func bomPrefixedJSONReturnsNil() {
        let bomPrefixed = "\u{FEFF}" + Self.json
        #expect(DockerParser.parseDiskUsage(bomPrefixed) == nil)
    }

    @Test("空输出返回 nil")
    func emptyReturnsNil() {
        #expect(DockerParser.parseDiskUsage("") == nil)
    }

    /// 字段缺失（某些版本 Volumes 为 null）不能崩。
    @Test("字段缺失时降级为空索引")
    func missingSectionsDegrade() throws {
        let usage = try #require(DockerParser.parseDiskUsage("""
        {"Images":null,"Volumes":null,"Containers":[],"BuildCache":[]}
        """))
        #expect(usage.volumeSize("pgdata") == nil)
        #expect(usage.imageSize("abc") == nil)
    }
}

@Suite("DockerCommand — 磁盘占用")
struct DockerDiskUsageCommandTests {
    @Test("命令形状")
    func command() {
        #expect(DockerCommand.diskUsage(sudo: false) == "docker system df -v --format '{{json .}}'")
        #expect(DockerCommand.diskUsage(sudo: true) == "sudo -n docker system df -v --format '{{json .}}'")
    }
}
