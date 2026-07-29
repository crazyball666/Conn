import Testing
@testable import ConnOps

@Suite("DockerParser — 镜像详情与层历史")
struct DockerImageDetailParserTests {
    static let inspectJSON = """
    [{"Id":"sha256:a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
      "RepoTags":["nginx:1.25","nginx:latest"],
      "RepoDigests":["nginx@sha256:deadbeef"],
      "Created":"2026-01-02T03:04:05.678Z",
      "Size":142000000,
      "Architecture":"amd64","Os":"linux",
      "Config":{"Entrypoint":["/docker-entrypoint.sh"],"Cmd":["nginx","-g","daemon off;"],
                "Env":["PATH=/usr/bin","NGINX_VERSION=1.25"],"Labels":{"maintainer":"nginx"}}}]
    """

    @Test("解析镜像详情")
    func parsesImageInspect() throws {
        let detail = try #require(DockerParser.parseImageInspect(Self.inspectJSON))
        #expect(detail.id == "a1b2c3d4e5f6")
        #expect(detail.tags == ["nginx:1.25", "nginx:latest"])
        #expect(detail.digest == "nginx@sha256:deadbeef")
        #expect(detail.architecture == "amd64")
        #expect(detail.os == "linux")
        #expect(detail.sizeBytes == 142_000_000)
        #expect(detail.entrypoint == "/docker-entrypoint.sh")
        #expect(detail.command == "nginx -g daemon off;")
        #expect(detail.env == ["NGINX_VERSION=1.25", "PATH=/usr/bin"])
        #expect(detail.labels == ["maintainer=nginx"])
        #expect(detail.created == "2026-01-02 03:04")
    }

    /// 无 tag 的悬空镜像、无 Config 的极简镜像都不能崩。
    @Test("字段缺失时降级而不是崩")
    func handlesMissingFields() throws {
        let json = """
        [{"Id":"sha256:abc","RepoTags":null,"Created":"","Size":0,"Architecture":"arm64","Os":"linux"}]
        """
        let detail = try #require(DockerParser.parseImageInspect(json))
        #expect(detail.tags.isEmpty)
        #expect(detail.digest == nil)
        #expect(detail.entrypoint == nil)
        #expect(detail.command == nil)
        #expect(detail.env.isEmpty)
        #expect(detail.created == "—")
    }

    @Test("坏输入返回 nil")
    func badInput() {
        #expect(DockerParser.parseImageInspect("") == nil)
        #expect(DockerParser.parseImageInspect("[]") == nil)
    }

    // swiftlint:disable line_length
    static let historyJSON = """
    {"Comment":"","CreatedAt":"2026-01-02T03:04:05Z","CreatedBy":"/bin/sh -c #(nop) CMD [\\"nginx\\"]","CreatedSince":"2 days ago","ID":"a1b2c3","Size":"0B"}
    {"Comment":"","CreatedAt":"2026-01-01T03:04:05Z","CreatedBy":"/bin/sh -c apt-get update && apt-get install -y curl","CreatedSince":"3 days ago","ID":"<missing>","Size":"58.2MB"}
    """
    // swiftlint:enable line_length

    @Test("解析层历史")
    func parsesHistory() {
        let layers = DockerParser.parseImageHistory(Self.historyJSON)
        #expect(layers.count == 2)
        #expect(layers[0].size == "0B")
        #expect(layers[1].size == "58.2MB")
        #expect(layers[1].createdBy.contains("apt-get"))
        #expect(layers[1].createdSince == "3 days ago")
    }

    @Test("空历史得空数组")
    func emptyHistory() {
        #expect(DockerParser.parseImageHistory("").isEmpty)
    }
}

@Suite("ImageUsage — 镜像是否被容器引用")
struct ImageUsageTests {
    private func image(_ repo: String, _ tag: String, id: String) -> ImageInfo {
        ImageInfo(imageID: id, repository: repo, tag: tag, size: "100MB", created: "2 days ago")
    }

    private func container(image: String) -> ContainerInfo {
        ContainerInfo(id: "c1", name: "c1", image: image, state: .running, status: "Up", ports: "")
    }

    /// 三种引用写法都要认出来。认漏 = 把在用的镜像标成「未使用」，
    /// 用户据此删掉就是事故——这是本任务最要紧的一条。
    @Test("repo:tag 引用被认出")
    func matchesByRepoTag() {
        let nginx = image("nginx", "1.25", id: "a1b2c3d4e5f6")
        let unused = ImageUsage.unusedImageIDs(
            images: [nginx], containers: [container(image: "nginx:1.25")]
        )
        #expect(unused.isEmpty)
    }

    @Test("完整 sha256 ID 引用被认出")
    func matchesByFullID() {
        let img = image("nginx", "1.25", id: "a1b2c3d4e5f6")
        let unused = ImageUsage.unusedImageIDs(
            images: [img],
            containers: [container(image: "sha256:a1b2c3d4e5f6a7b8c9d0")]
        )
        #expect(unused.isEmpty, "容器用完整 ID 引用时也必须算在用")
    }

    @Test("短 ID 引用被认出")
    func matchesByShortID() {
        let img = image("nginx", "1.25", id: "a1b2c3d4e5f6")
        let unused = ImageUsage.unusedImageIDs(
            images: [img], containers: [container(image: "a1b2c3d4e5f6")]
        )
        #expect(unused.isEmpty)
    }

    /// `docker run` 接受任意不歧义前缀，容器的 `image` 字段可能比 12 位短 ID
    /// 还短。只判「bare 是 imageID 前缀」这一个方向认不出这种写法——必须两个
    /// 方向都判，见 `ImageUsage.matches` 的注释。
    @Test("比 12 位短 ID 更短的前缀引用也被认出")
    func matchesByShorterPrefix() {
        let img = image("nginx", "1.25", id: "a1b2c3d4e5f6")
        let unused = ImageUsage.unusedImageIDs(
            images: [img], containers: [container(image: "a1b2c3")]
        )
        #expect(unused.isEmpty, "容器引用比短 ID 更短的前缀时也必须算在用")
    }

    @Test("真正没人用的镜像被标出")
    func detectsUnused() {
        let used = image("nginx", "1.25", id: "aaa111222333")
        let orphan = image("redis", "7", id: "bbb444555666")
        let unused = ImageUsage.unusedImageIDs(
            images: [used, orphan], containers: [container(image: "nginx:1.25")]
        )
        #expect(unused == [orphan.id])
    }

    /// 已停止的容器同样算「在用」——镜像被它引用着就删不掉。
    @Test("已停止的容器也算在用")
    func stoppedContainerStillCounts() {
        let img = image("nginx", "1.25", id: "a1b2c3d4e5f6")
        let stopped = ContainerInfo(
            id: "c2", name: "c2", image: "nginx:1.25", state: .exited, status: "Exited (0)", ports: ""
        )
        #expect(ImageUsage.unusedImageIDs(images: [img], containers: [stopped]).isEmpty)
    }

    @Test("反查引用某镜像的容器")
    func findsContainersUsingImage() {
        let img = image("nginx", "1.25", id: "a1b2c3d4e5f6")
        // `b` 在 .swiftlint.yml 里被排除（RGB 惯用名），`a` 未被排除；两者对称沿用同一命名。
        // swiftlint:disable:next identifier_name
        let a = ContainerInfo(id: "a", name: "web-1", image: "nginx:1.25", state: .running, status: "Up", ports: "")
        let b = ContainerInfo(id: "b", name: "pg-1", image: "postgres:16", state: .running, status: "Up", ports: "")
        let hits = ImageUsage.containersUsing(img, in: [a, b])
        #expect(hits.map(\.name) == ["web-1"])
    }
}
