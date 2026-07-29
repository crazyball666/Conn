# Docker 只读补全（第一期）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Docker 分段从「容器 / 镜像」扩到「容器 / 镜像 / 卷 / 网络」，补上镜像详情、卷与网络的列表与详情，并回答「被谁在用」「什么能删」「磁盘被什么吃了」三个问题。全部只读。

**Architecture:** 沿用既有分层——`DockerCommand` 拼命令串、`DockerParser` 解析 `{{json .}}` 输出、`DockerService` 取数，三者皆纯函数或薄封装，是测试主战场；App 侧把已经 197 行的 `DockerViewModel` 拆成「外壳 + 四个资源模型」，每个一个职责。

**Tech Stack:** Swift 5.10 / iOS 17 / SwiftUI + Observation / Swift Testing（`@Test` `#expect`）/ SwiftLint。

设计依据：`docs/superpowers/specs/2026-07-29-docker-readonly-design.md`。

## Global Constraints

- **平台基线 iOS 17**，SPM 包 `platforms: [.iOS(.v17), .macOS("15.0")]`，不得提高。macOS 那行不是为了出 Mac 版，而是满足 GRDB/Citadel/SwiftTerm 的下限并让 `swift test` 能在本机跑；ConnOps 会被按 macOS 编译一遍。
- **全部经 `docker` CLI 走 exec，不引入 Docker API socket**（方案 §4.4）。
- **`sudo -n` 前缀机制不改**：所有新命令一律经 `DockerCommand.prefix(sudo)`，与现有一致。
- **本期不新增任何写操作。** 现有的 `removeImage` / `pruneImages` 保持原样，不扩展、不改签名。
- **「未使用」语义分两类，不可混用**：卷与网络直接信 Docker 的 `dangling=true`；**镜像不能用 dangling**（那是「无 tag」），必须由容器列表反查。详见 Task 2。
- **磁盘占用绝不阻塞列表**：单独异步加载，解析失败显示「—」且**不弹错误**。
- 注释与文档字符串用**中文**，解释「为什么」而非复述代码。
- 面向用户的文案走 `L("…")`，五语齐全（zh-Hans 源串 + en / ja / ko / zh-Hant）。新文案落在 App 侧 catalog `Conn/Conn/Localizable.xcstrings`。
- **SwiftLint 基线 6 条既有警告**，标准是**不新增**。必须在 `Tooling/` 下运行：`cd Tooling && swiftlint lint --quiet | wc -l`（仓库根运行会漏掉 `.build` 排除规则）。
- **包测试**：`cd Packages/ConnPackages && swift test --filter <Suite>`。
- **App 构建**：`cd /Users/crazyball/Code/Swift/Conn && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug`
- **跨模块改动后若 `swift test` 出现莫名其妙的失败或链接错误**，先 `rm -rf .build/debug` 再判断——本仓库有过 SwiftPM 增量构建导致 enum case 标签错位、五条无关测试变红的先例。
- **不要启动新模拟器**。先 `xcrun simctl list devices booted`；全 Shutdown 时从**已存在**的设备里挑一台 iPhone `xcrun simctl bootstatus <udid> -b`。已知 `3E72DF80-…` 有 CoreSimulator 权限故障，同机 `EAA9BFB6-2D92-4831-9CFE-005A20FE35C4` 可用。
- **DerivedData 里有多个 `Conn.app`**，装包前按时间取最新：`ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1`

## 文件结构

**新建（ConnOps 域层，各一个类型一个文件，与现有 `ContainerInfo.swift` 同规格）**

| 文件 | 职责 |
|---|---|
| `Sources/ConnOps/VolumeInfo.swift` | 卷列表项 + 卷详情 |
| `Sources/ConnOps/NetworkInfo.swift` | 网络列表项 + 网络详情 |
| `Sources/ConnOps/ImageDetail.swift` | 镜像详情 + 单层历史 |
| `Sources/ConnOps/DockerDiskUsage.swift` | 磁盘占用索引 |
| `Sources/ConnOps/ImageUsage.swift` | 镜像「被哪些容器引用」的纯判定 |

**修改（ConnOps）**：`DockerCommand.swift`（加命令）、`DockerParser.swift`（加解析）、`DockerService.swift`（加取数）。

**新建（App 侧状态）**

| 文件 | 职责 |
|---|---|
| `Conn/Hosts/DockerContainersModel.swift` | 容器列表 + 动作（从 `DockerViewModel` 搬出，行为不变） |
| `Conn/Hosts/DockerImagesModel.swift` | 镜像列表 + 详情 + 层历史 + 未使用判定 |
| `Conn/Hosts/DockerVolumesModel.swift` | 卷列表 + 详情 |
| `Conn/Hosts/DockerNetworksModel.swift` | 网络列表 + 详情 |

**新建（App 侧视图）**：`Conn/Hosts/ImageDetailView.swift`、`Conn/Hosts/VolumeDetailView.swift`、`Conn/Hosts/NetworkDetailView.swift`。

**修改（App 侧）**：`DockerViewModel.swift`（瘦成外壳）、`DockerView.swift`（分段 2→4、接搜索框、路由）、`Demo/DemoOps.swift`（演示数据）。

---

### Task 1: 卷与网络的域模型、命令与解析

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/VolumeInfo.swift`
- Create: `Packages/ConnPackages/Sources/ConnOps/NetworkInfo.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerParser.swift`
- Test: `Packages/ConnPackages/Tests/ConnOpsTests/DockerVolumeNetworkParserTests.swift`（新建）

**Interfaces:**
- Consumes: 无（第一个任务）。
- Produces:
  - `VolumeInfo(name:driver:scope:mountpoint:)`，`var id: String { name }`
  - `VolumeDetail(name:driver:mountpoint:createdAt:labels:options:)`
  - `NetworkInfo(id:name:driver:scope:)`，`var isPredefined: Bool`
  - `NetworkDetail(id:name:driver:scope:subnet:gateway:isInternal:attachedContainers:)`
  - `NetworkDetail.AttachedContainer(id:name:ipv4:)`
  - `DockerCommand.volumes(sudo:)` / `.danglingVolumes(sudo:)` / `.volumeInspect(name:sudo:)`
  - `DockerCommand.networks(sudo:)` / `.danglingNetworks(sudo:)` / `.networkInspect(name:sudo:)`
  - `DockerParser.parseVolumes(_:) -> [VolumeInfo]`
  - `DockerParser.parseVolumeInspect(_:) -> VolumeDetail?`
  - `DockerParser.parseNetworks(_:) -> [NetworkInfo]`
  - `DockerParser.parseNetworkInspect(_:) -> NetworkDetail?`
  - `DockerParser.parseNameList(_:) -> Set<String>`（`ls --filter dangling=true -q` 的名字集合）

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnOpsTests/DockerVolumeNetworkParserTests.swift`：

```swift
import Testing
@testable import ConnOps

@Suite("DockerParser — 卷与网络")
struct DockerVolumeNetworkParserTests {
    /// 取自 `docker volume ls --format '{{json .}}'` 的真实输出形状。
    /// 注意 Size 恒为 N/A——卷大小 docker volume ls 根本不给，只能靠 system df。
    static let volumeLines = """
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"com.docker.compose.project=web","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/web_assets/_data","Name":"web_assets","Scope":"local","Size":"N/A","Status":"N/A"}
    """

    @Test("解析卷列表")
    func parsesVolumes() {
        let volumes = DockerParser.parseVolumes(Self.volumeLines)
        #expect(volumes.count == 2)
        #expect(volumes[0].name == "pgdata")
        #expect(volumes[0].driver == "local")
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

    static let networkLines = """
    {"CreatedAt":"2026-01-02 03:04:05","Driver":"bridge","ID":"a1b2c3d4e5f6","IPv6":"false","Internal":"false","Labels":"","Name":"bridge","Scope":"local"}
    {"CreatedAt":"2026-02-03 04:05:06","Driver":"bridge","ID":"f6e5d4c3b2a1","IPv6":"false","Internal":"false","Labels":"","Name":"web_default","Scope":"local"}
    """

    @Test("解析网络列表")
    func parsesNetworks() {
        let networks = DockerParser.parseNetworks(Self.networkLines)
        #expect(networks.count == 2)
        #expect(networks[0].name == "bridge")
        #expect(networks[0].driver == "bridge")
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

    static let volumeInspectJSON = """
    [{"CreatedAt":"2026-01-02T03:04:05Z","Driver":"local","Labels":{"com.docker.compose.project":"web"},"Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Options":{"type":"none"},"Scope":"local"}]
    """

    @Test("解析卷详情")
    func parsesVolumeInspect() throws {
        let detail = try #require(DockerParser.parseVolumeInspect(Self.volumeInspectJSON))
        #expect(detail.name == "pgdata")
        #expect(detail.mountpoint == "/var/lib/docker/volumes/pgdata/_data")
        #expect(detail.createdAt == "2026-01-02 03:04")
        #expect(detail.labels == ["com.docker.compose.project=web"])
        #expect(detail.options == ["type=none"])
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
        #expect(detail.name == "web_default")
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
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter DockerVolumeNetwork 2>&1 | grep -E "error:|✘|Test run" | head -5
```

Expected: 编译失败 —— `VolumeInfo` / `NetworkInfo` / 各解析与命令函数都不存在。

- [ ] **Step 3: 建卷模型**

新建 `Packages/ConnPackages/Sources/ConnOps/VolumeInfo.swift`：

```swift
import Foundation

/// 卷列表项（`docker volume ls`）。
///
/// **没有大小字段**：`docker volume ls` 的 `Size` 恒为 `N/A`，卷占用只能靠
/// `docker system df -v`，那条单独异步取（见 `DockerDiskUsage`）。
public struct VolumeInfo: Identifiable, Equatable, Sendable {
    public let name: String
    public let driver: String
    public let scope: String
    public let mountpoint: String

    public var id: String { name }

    public init(name: String, driver: String, scope: String, mountpoint: String) {
        self.name = name
        self.driver = driver
        self.scope = scope
        self.mountpoint = mountpoint
    }
}

/// 卷详情（`docker volume inspect`）。
public struct VolumeDetail: Equatable, Sendable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    /// `2026-01-02 03:04`。缺失为「—」。
    public let createdAt: String
    /// `key=value` 形式，已排序——JSON 字典无序，不排会让 UI 每次刷新跳动。
    public let labels: [String]
    public let options: [String]

    public init(
        name: String, driver: String, mountpoint: String,
        createdAt: String, labels: [String], options: [String]
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.labels = labels
        self.options = options
    }
}
```

- [ ] **Step 4: 建网络模型**

新建 `Packages/ConnPackages/Sources/ConnOps/NetworkInfo.swift`：

```swift
import Foundation

/// 网络列表项（`docker network ls`）。
public struct NetworkInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String

    public init(id: String, name: String, driver: String, scope: String) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
    }

    /// Docker 预置的三张网，永远删不掉。
    ///
    /// 「未使用」徽标必须排除它们：`network ls --filter dangling=true` 会把没有容器
    /// 接入的 `bridge` / `host` / `none` 一并列出，而对它们打徽标只是噪声——
    /// 用户既不能也不该删。
    public var isPredefined: Bool {
        name == "bridge" || name == "host" || name == "none"
    }
}

/// 网络详情（`docker network inspect`）。
public struct NetworkDetail: Equatable, Sendable {
    /// 接入该网的容器。`docker network inspect` 直接给，**无需额外命令**。
    public struct AttachedContainer: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let ipv4: String?

        public init(id: String, name: String, ipv4: String?) {
            self.id = id
            self.name = name
            self.ipv4 = ipv4
        }
    }

    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let subnet: String?
    public let gateway: String?
    public let isInternal: Bool
    /// 按容器名排序——JSON 字典无序，不排会让 UI 每次刷新跳动。
    public let attachedContainers: [AttachedContainer]

    public init(
        id: String, name: String, driver: String, scope: String,
        subnet: String?, gateway: String?, isInternal: Bool,
        attachedContainers: [AttachedContainer]
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
        self.subnet = subnet
        self.gateway = gateway
        self.isInternal = isInternal
        self.attachedContainers = attachedContainers
    }
}
```

- [ ] **Step 5: 加命令**

`DockerCommand.swift` 里 `pruneImages` 之后、`logs` 之前插入：

```swift
    // MARK: - 卷

    /// 全部卷，JSON 每行一个。
    public static func volumes(sudo: Bool) -> String {
        prefix(sudo) + "docker volume ls --format '{{json .}}'"
    }

    /// 无任何容器引用的卷名。对卷而言 `dangling` 的定义就是「没被引用」，
    /// 与我们要表达的「未使用」一致，故直接用它而不在客户端比对容器列表。
    public static func danglingVolumes(sudo: Bool) -> String {
        prefix(sudo) + "docker volume ls --filter dangling=true -q"
    }

    /// 卷详情（JSON 数组）。
    public static func volumeInspect(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker volume inspect \(name)"
    }

    // MARK: - 网络

    /// 全部网络，JSON 每行一个。
    public static func networks(sudo: Bool) -> String {
        prefix(sudo) + "docker network ls --format '{{json .}}'"
    }

    /// 无容器接入的网络名。**注意它会包含预置的 bridge / host / none**，
    /// 打徽标前须用 `NetworkInfo.isPredefined` 滤掉。
    ///
    /// 用 `--format '{{.Name}}'` 而非 `-q`：`-q` 给的是网络 ID，而列表项与
    /// inspect 都以名字为键，取 ID 还要再映射一次。
    public static func danglingNetworks(sudo: Bool) -> String {
        prefix(sudo) + "docker network ls --filter dangling=true --format '{{.Name}}'"
    }

    /// 网络详情（JSON 数组）。
    public static func networkInspect(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker network inspect \(name)"
    }
```

- [ ] **Step 6: 加解析**

`DockerParser.swift` 的 `// MARK: - inspect` 之前插入：

```swift
    // MARK: - 卷

    public static func parseVolumes(_ output: String) -> [VolumeInfo] {
        decodeLines(output).map { (line: VolumeLine) in
            VolumeInfo(
                name: line.name,
                driver: line.driver,
                scope: line.scope ?? "local",
                mountpoint: line.mountpoint ?? "—"
            )
        }
    }

    /// `docker volume inspect <名>`（JSON 数组，取首个）。空/坏输出返回 nil。
    public static func parseVolumeInspect(_ output: String) -> VolumeDetail? {
        guard let dto: VolumeInspectDTO = decodeFirst(output) else { return nil }
        return VolumeDetail(
            name: dto.name,
            driver: dto.driver,
            mountpoint: dto.mountpoint ?? "—",
            createdAt: shortDate(dto.createdAt ?? ""),
            labels: keyValueList(dto.labels),
            options: keyValueList(dto.options)
        )
    }

    // MARK: - 网络

    public static func parseNetworks(_ output: String) -> [NetworkInfo] {
        decodeLines(output).map { (line: NetworkLine) in
            NetworkInfo(id: line.id, name: line.name, driver: line.driver, scope: line.scope ?? "local")
        }
    }

    /// `docker network inspect <名>`（JSON 数组，取首个）。空/坏输出返回 nil。
    public static func parseNetworkInspect(_ output: String) -> NetworkDetail? {
        guard let dto: NetworkInspectDTO = decodeFirst(output) else { return nil }
        let ipam = dto.ipam?.config?.first
        let attached = (dto.containers ?? [:])
            .map { id, container in
                NetworkDetail.AttachedContainer(id: id, name: container.name ?? id, ipv4: container.ipv4Address)
            }
            // JSON 字典无序：不排序则每次刷新顺序都可能变，UI 会莫名跳动
            .sorted { $0.name < $1.name }
        return NetworkDetail(
            id: dto.id,
            name: dto.name,
            driver: dto.driver ?? "—",
            scope: dto.scope ?? "local",
            subnet: ipam?.subnet,
            gateway: ipam?.gateway,
            isInternal: dto.isInternal ?? false,
            attachedContainers: attached
        )
    }

    /// `ls --filter dangling=true` 的名字输出 → 集合。空行剔除。
    public static func parseNameList(_ output: String) -> Set<String> {
        Set(
            output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
```

同文件 `// MARK: - 通用` 区加两个辅助：

```swift
    /// JSON 数组取首个元素解码。`docker X inspect` 全都是这个形状。
    private static func decodeFirst<T: Decodable>(_ output: String) -> T? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([T].self, from: data))?.first
    }

    /// `{"a":"1","b":"2"}` → `["a=1", "b=2"]`。已排序，nil 得空数组。
    private static func keyValueList(_ dict: [String: String]?) -> [String] {
        (dict ?? [:]).map { "\($0.key)=\($0.value)" }.sorted()
    }
```

文件末尾 DTO 区追加：

```swift
private struct VolumeLine: Decodable {
    let name: String
    let driver: String
    let scope: String?
    let mountpoint: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", scope = "Scope", mountpoint = "Mountpoint"
    }
}

private struct NetworkLine: Decodable {
    let id: String
    let name: String
    let driver: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", driver = "Driver", scope = "Scope"
    }
}

private struct VolumeInspectDTO: Decodable {
    let name: String
    let driver: String
    let mountpoint: String?
    let createdAt: String?
    let labels: [String: String]?
    let options: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint"
        case createdAt = "CreatedAt", labels = "Labels", options = "Options"
    }
}

private struct NetworkInspectDTO: Decodable {
    let id: String
    let name: String
    let driver: String?
    let scope: String?
    let isInternal: Bool?
    let ipam: NetworkIPAM?
    let containers: [String: NetworkContainerDTO]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", scope = "Scope"
        case isInternal = "Internal", ipam = "IPAM", containers = "Containers"
    }
}

private struct NetworkIPAM: Decodable {
    let config: [NetworkIPAMConfig]?
    enum CodingKeys: String, CodingKey { case config = "Config" }
}

private struct NetworkIPAMConfig: Decodable {
    let subnet: String?
    let gateway: String?
    enum CodingKeys: String, CodingKey { case subnet = "Subnet", gateway = "Gateway" }
}

private struct NetworkContainerDTO: Decodable {
    let name: String?
    let ipv4Address: String?
    enum CodingKeys: String, CodingKey { case name = "Name", ipv4Address = "IPv4Address" }
}
```

- [ ] **Step 7: 跑测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter DockerVolumeNetwork 2>&1 | grep -E "✘|Test run" | head -5
```

Expected: 12 条全 PASS。

- [ ] **Step 8: 变异验证**

三次变异，每次跑上面的命令，确认对应用例变红后还原：

1. `NetworkInfo.isPredefined` 里去掉 `|| name == "none"` → `predefinedNetworks` 应变红。
2. `parseNetworkInspect` 里去掉 `.sorted { $0.name < $1.name }` → `parsesNetworkInspect` 的顺序断言应变红（若未变红，说明字典恰好有序，换成三个容器再试）。
3. `parseVolumeInspect` 里 `keyValueList(dto.labels)` 改成 `[]` → `parsesVolumeInspect` 应变红。

三次都还原后 `git diff` 确认无残留，把失败输出写进报告。

> 若某次变异**没有**让测试变红，说明那条测试是空转的，必须先把测试修到能红再继续
> ——本仓库此前已抓到过四次假测试。

- [ ] **Step 9: 构建 + lint + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
cd /Users/crazyball/Code/Swift/Conn && git add -A && git commit -m "feat(ops): 卷与网络的域模型、命令与解析

网络的接入容器由 network inspect 直接给出，零额外命令。
卷与网络的「未使用」直接用 Docker 的 dangling 语义——对这两类它的定义
就是「没有任何容器引用」；但 dangling 会包含预置的 bridge/host/none，
故 NetworkInfo 自带 isPredefined 供上层滤掉。
inspect 的字典字段一律排序输出，否则 JSON 无序会让 UI 每次刷新跳动。"
```

Expected: 无 error；lint 为 6。

---

### Task 2: 镜像详情、层历史与「未被使用」判定

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/ImageDetail.swift`
- Create: `Packages/ConnPackages/Sources/ConnOps/ImageUsage.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerParser.swift`
- Test: `Packages/ConnPackages/Tests/ConnOpsTests/DockerImageDetailTests.swift`（新建）

**Interfaces:**
- Consumes: Task 1 的 `DockerParser.decodeFirst` 与 `keyValueList`（同文件私有，直接可用）。
- Produces:
  - `ImageDetail(id:tags:digest:architecture:os:sizeBytes:entrypoint:command:env:labels:created:)`
  - `ImageLayer(id:createdBy:size:createdSince:)`
  - `DockerCommand.imageInspect(reference:sudo:)` / `.imageHistory(reference:sudo:)`
  - `DockerParser.parseImageInspect(_:) -> ImageDetail?`
  - `DockerParser.parseImageHistory(_:) -> [ImageLayer]`
  - `ImageUsage.unusedImageIDs(images:containers:) -> Set<String>`
  - `ImageUsage.containersUsing(_:in:) -> [ContainerInfo]`

**本任务最容易出错的地方**：容器引用镜像有三种写法，必须全部认出来，否则会把**在用的镜像标成未使用**，用户据此删掉就是事故：

| 容器的 `image` 字段 | 对应镜像 |
|---|---|
| `nginx:1.25` | repository:tag 完全匹配 |
| `sha256:a1b2c3…`（64 位）或 `a1b2c3…` | 完整镜像 ID |
| `a1b2c3d4e5f6`（12 位短 ID） | `docker images` 给的就是短 ID |

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnOpsTests/DockerImageDetailTests.swift`：

```swift
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

    static let historyJSON = """
    {"Comment":"","CreatedAt":"2026-01-02T03:04:05Z","CreatedBy":"/bin/sh -c #(nop) CMD [\\"nginx\\"]","CreatedSince":"2 days ago","ID":"a1b2c3","Size":"0B"}
    {"Comment":"","CreatedAt":"2026-01-01T03:04:05Z","CreatedBy":"/bin/sh -c apt-get update && apt-get install -y curl","CreatedSince":"3 days ago","ID":"<missing>","Size":"58.2MB"}
    """

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
        let a = ContainerInfo(id: "a", name: "web-1", image: "nginx:1.25", state: .running, status: "Up", ports: "")
        let b = ContainerInfo(id: "b", name: "pg-1", image: "postgres:16", state: .running, status: "Up", ports: "")
        let hits = ImageUsage.containersUsing(img, in: [a, b])
        #expect(hits.map(\.name) == ["web-1"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter "DockerImageDetail|ImageUsage" 2>&1 | grep -E "error:|✘|Test run" | head -5
```

Expected: 编译失败 —— `ImageDetail` / `ImageLayer` / `ImageUsage` 及各函数不存在。

- [ ] **Step 3: 建镜像详情模型**

新建 `Packages/ConnPackages/Sources/ConnOps/ImageDetail.swift`：

```swift
import Foundation

/// 镜像详情（`docker image inspect`）。
public struct ImageDetail: Equatable, Sendable {
    /// 12 位短 ID，与 `ImageInfo.imageID` 同规格便于比对。
    public let id: String
    public let tags: [String]
    public let digest: String?
    public let architecture: String
    public let os: String
    /// 字节数。`docker image inspect` 给的是数值，不是 `docker images` 那种 `142MB` 串。
    public let sizeBytes: Int64
    public let entrypoint: String?
    public let command: String?
    /// 已排序——JSON 数组本身有序但 Labels 是字典，统一排序保证 UI 稳定。
    public let env: [String]
    public let labels: [String]
    /// `2026-01-02 03:04`。缺失为「—」。
    public let created: String

    public init(
        id: String, tags: [String], digest: String?, architecture: String, os: String,
        sizeBytes: Int64, entrypoint: String?, command: String?,
        env: [String], labels: [String], created: String
    ) {
        self.id = id
        self.tags = tags
        self.digest = digest
        self.architecture = architecture
        self.os = os
        self.sizeBytes = sizeBytes
        self.entrypoint = entrypoint
        self.command = command
        self.env = env
        self.labels = labels
        self.created = created
    }
}

/// 镜像的一层（`docker history`）。
///
/// 层的 `ID` 常常是 `<missing>`（非本地构建的层拿不到 ID），所以**不能拿它做
/// Identifiable 的键**，用下标。
public struct ImageLayer: Equatable, Sendable {
    public let id: String
    /// 构建该层的指令。`docker history` 已做过截断处理的原样输出。
    public let createdBy: String
    /// `58.2MB` 这类人类可读串，直接来自 docker。
    public let size: String
    public let createdSince: String

    public init(id: String, createdBy: String, size: String, createdSince: String) {
        self.id = id
        self.createdBy = createdBy
        self.size = size
        self.createdSince = createdSince
    }
}
```

- [ ] **Step 4: 建「被谁引用」判定**

新建 `Packages/ConnPackages/Sources/ConnOps/ImageUsage.swift`：

```swift
import Foundation

/// 镜像与容器的引用关系判定。纯函数，不碰网络。
///
/// **为什么不用 `docker images --filter dangling=true`**：那个过滤器给的是
/// 「无 tag」的镜像，与「没被容器引用」是两码事——一个打了 tag 的镜像完全
/// 可能没人用。拿 dangling 当「未使用」会漏掉一大批真正能删的镜像，更糟的是
/// 反过来让用户以为「没标徽标 = 还在用」而不敢删。
///
/// 容器段本来就要拉 `docker ps -a`，把那份结果拿来比对即可，**不额外跑命令**。
public enum ImageUsage {
    /// 没有任何容器引用的镜像 id 集合（`ImageInfo.id`）。
    public static func unusedImageIDs(
        images: [ImageInfo],
        containers: [ContainerInfo]
    ) -> Set<String> {
        let referenced = containers.map(\.image)
        return Set(
            images
                .filter { image in !referenced.contains { matches(image, reference: $0) } }
                .map(\.id)
        )
    }

    /// 引用某镜像的容器（含已停止的——它引用着就删不掉该镜像）。
    public static func containersUsing(
        _ image: ImageInfo,
        in containers: [ContainerInfo]
    ) -> [ContainerInfo] {
        containers.filter { matches(image, reference: $0.image) }
    }

    /// 容器的 `image` 字段是否指向该镜像。
    ///
    /// 三种写法都要认：`repo:tag`、完整 ID（可带 `sha256:` 前缀）、12 位短 ID。
    /// 认漏会把在用的镜像标成「未使用」，用户据此删掉就是事故。
    private static func matches(_ image: ImageInfo, reference: String) -> Bool {
        if reference == image.reference { return true }
        let bare = reference.hasPrefix("sha256:")
            ? String(reference.dropFirst("sha256:".count))
            : reference
        // ImageInfo.imageID 是 docker images 给的 12 位短 ID；容器可能给完整 64 位。
        // 两个方向都要判：短的是长的前缀，或反过来。
        guard !bare.isEmpty, !image.imageID.isEmpty else { return false }
        return bare.hasPrefix(image.imageID) || image.imageID.hasPrefix(bare)
    }
}
```

- [ ] **Step 5: 加命令与解析**

`DockerCommand.swift` 的卷区之前插入：

```swift
    /// 镜像详情（JSON 数组）。
    public static func imageInspect(reference: String, sudo: Bool) -> String {
        prefix(sudo) + "docker image inspect \(reference)"
    }

    /// 镜像层历史，JSON 每行一个。`--no-trunc` 不加：指令过长在手机上没法读，
    /// docker 默认的截断正合适。
    public static func imageHistory(reference: String, sudo: Bool) -> String {
        prefix(sudo) + "docker history \(reference) --format '{{json .}}'"
    }
```

`DockerParser.swift` 的 `// MARK: - 卷` 之前插入：

```swift
    // MARK: - 镜像详情

    /// `docker image inspect <引用>`（JSON 数组，取首个）。空/坏输出返回 nil。
    public static func parseImageInspect(_ output: String) -> ImageDetail? {
        guard let dto: ImageInspectDTO = decodeFirst(output) else { return nil }
        let bareID = dto.id.hasPrefix("sha256:") ? String(dto.id.dropFirst(7)) : dto.id
        let entrypoint = (dto.config?.entrypoint ?? []).joined(separator: " ")
        let command = (dto.config?.cmd ?? []).joined(separator: " ")
        return ImageDetail(
            id: String(bareID.prefix(12)),
            tags: dto.repoTags ?? [],
            digest: dto.repoDigests?.first,
            architecture: dto.architecture ?? "—",
            os: dto.os ?? "—",
            sizeBytes: dto.size ?? 0,
            entrypoint: entrypoint.isEmpty ? nil : entrypoint,
            command: command.isEmpty ? nil : command,
            env: (dto.config?.env ?? []).sorted(),
            labels: keyValueList(dto.config?.labels),
            created: shortDate(dto.created ?? "")
        )
    }

    public static func parseImageHistory(_ output: String) -> [ImageLayer] {
        decodeLines(output).map { (line: HistoryLine) in
            ImageLayer(
                id: line.id,
                createdBy: line.createdBy,
                size: line.size,
                createdSince: line.createdSince
            )
        }
    }
```

文件末尾 DTO 区追加：

```swift
private struct ImageInspectDTO: Decodable {
    let id: String
    let repoTags: [String]?
    let repoDigests: [String]?
    let created: String?
    let size: Int64?
    let architecture: String?
    let os: String?
    let config: ImageConfigDTO?

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests"
        case created = "Created", size = "Size", architecture = "Architecture"
        case os = "Os", config = "Config"
    }
}

private struct ImageConfigDTO: Decodable {
    let entrypoint: [String]?
    let cmd: [String]?
    let env: [String]?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case entrypoint = "Entrypoint", cmd = "Cmd", env = "Env", labels = "Labels"
    }
}

private struct HistoryLine: Decodable {
    let id: String
    let createdBy: String
    let size: String
    let createdSince: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", createdBy = "CreatedBy", size = "Size", createdSince = "CreatedSince"
    }
}
```

- [ ] **Step 6: 跑测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter "DockerImageDetail|ImageUsage" 2>&1 | grep -E "✘|Test run" | head -5
```

Expected: 12 条全 PASS。

- [ ] **Step 7: 变异验证**

四次变异，重点打「三种引用写法」那条：

1. `matches` 里删掉 `sha256:` 剥前缀那两行（直接用 `reference`）→ `matchesByFullID` 应变红。
2. `matches` 里把 `bare.hasPrefix(image.imageID) || image.imageID.hasPrefix(bare)` 改成只留前半 → `matchesByShortID` 或 `matchesByFullID` 之一应变红。
3. `matches` 首行 `reference == image.reference` 改成 `false` → `matchesByRepoTag` 应变红。
4. `parseImageInspect` 里 `.sorted()` 去掉 → `parsesImageInspect` 的 env 断言应变红。

四次都还原后 `git diff` 确认无残留，把失败输出写进报告。

- [ ] **Step 8: 构建 + lint + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
cd /Users/crazyball/Code/Swift/Conn && git add -A && git commit -m "feat(ops): 镜像详情、层历史与「未被使用」判定

镜像的「未使用」不能用 docker images --filter dangling=true——那是「无 tag」，
与「没被容器引用」是两码事。改由容器列表反查，容器段本来就要拉 ps -a，
不额外跑命令。三种引用写法（repo:tag / 完整 sha256 ID / 12 位短 ID）都要认，
认漏会把在用的镜像标成未使用，用户据此删掉即事故——四次变异验证专打这条。"
```

Expected: 无 error；lint 为 6。

---

### Task 3: 磁盘占用（`docker system df -v`）

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/DockerDiskUsage.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerParser.swift`
- Test: `Packages/ConnPackages/Tests/ConnOpsTests/DockerDiskUsageTests.swift`（新建）

**Interfaces:**
- Consumes: Task 1 的 `decodeFirst`。
- Produces:
  - `DockerDiskUsage(volumeSizes:imageSizes:)`，`func volumeSize(_ name: String) -> String?`、`func imageSize(_ id: String) -> String?`
  - `DockerCommand.diskUsage(sudo:)`
  - `DockerParser.parseDiskUsage(_:) -> DockerDiskUsage?`

**为什么单独一个任务**：这条命令的输出格式跨 Docker 版本不稳，是本期唯一一处
「可能在真实主机上解析不出来」的地方，必须能独立失败而不拖累其它功能。

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnOpsTests/DockerDiskUsageTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter DockerDiskUsage 2>&1 | grep -E "error:|✘|Test run" | head -5
```

Expected: 编译失败 —— `DockerDiskUsage` 与 `parseDiskUsage` / `diskUsage` 不存在。

- [ ] **Step 3: 建模型**

新建 `Packages/ConnPackages/Sources/ConnOps/DockerDiskUsage.swift`：

```swift
import Foundation

/// `docker system df -v` 的占用索引。
///
/// **只做索引，不做展示**：值是 docker 给的人类可读串（`1.2GB`），
/// 直接透传，不在客户端重新格式化——不同 docker 版本的单位口径不一致，
/// 二次加工只会引入偏差。
///
/// 查不到一律返回 nil，上层显示「—」。这条命令在大主机上要数秒且格式跨版本
/// 不稳，**它失败不该让任何列表看起来坏了**。
public struct DockerDiskUsage: Equatable, Sendable {
    /// 卷名 → 占用。
    private let volumeSizes: [String: String]
    /// 12 位短镜像 ID → 占用。
    private let imageSizes: [String: String]

    public init(volumeSizes: [String: String], imageSizes: [String: String]) {
        self.volumeSizes = volumeSizes
        self.imageSizes = imageSizes
    }

    public func volumeSize(_ name: String) -> String? { volumeSizes[name] }

    /// - Parameter id: 12 位短 ID（`ImageInfo.imageID` 的规格）。
    public func imageSize(_ id: String) -> String? { imageSizes[id] }
}
```

- [ ] **Step 4: 加命令与解析**

`DockerCommand.swift` 的镜像区之后插入：

```swift
    /// 磁盘占用明细。**这条在镜像/卷多的主机上要数秒**，调用方须单独异步取，
    /// 不可与列表串在一起。`--format json` 在较老 docker 上不支持，
    /// 那时输出是表格文本，解析器会返回 nil，上层显示「—」。
    public static func diskUsage(sudo: Bool) -> String {
        prefix(sudo) + "docker system df -v --format '{{json .}}'"
    }
```

`DockerParser.swift` 的 `// MARK: - 通用` 之前插入：

```swift
    // MARK: - 磁盘占用

    /// `docker system df -v --format '{{json .}}'` → 占用索引。
    ///
    /// 老版本 docker 不支持该 `--format`，吐出的是表格文本；此时返回 nil，
    /// 让上层显示「—」而不是崩或给出错误数字。
    public static func parseDiskUsage(_ output: String) -> DockerDiskUsage? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DiskUsageDTO.self, from: data)
        else { return nil }

        var volumes: [String: String] = [:]
        for entry in dto.volumes ?? [] {
            volumes[entry.name] = entry.size
        }
        var images: [String: String] = [:]
        for entry in dto.images ?? [] {
            // system df 给带 sha256: 前缀的长 ID，而 docker images 给 12 位短 ID。
            // 不归一化成同一规格，imageSize 永远查不到。
            let bare = entry.id.hasPrefix("sha256:") ? String(entry.id.dropFirst(7)) : entry.id
            images[String(bare.prefix(12))] = entry.size
        }
        return DockerDiskUsage(volumeSizes: volumes, imageSizes: images)
    }
```

文件末尾 DTO 区追加：

```swift
private struct DiskUsageDTO: Decodable {
    let images: [DiskUsageImage]?
    let volumes: [DiskUsageVolume]?
    enum CodingKeys: String, CodingKey { case images = "Images", volumes = "Volumes" }
}

private struct DiskUsageImage: Decodable {
    let id: String
    let size: String
    enum CodingKeys: String, CodingKey { case id = "ID", size = "Size" }
}

private struct DiskUsageVolume: Decodable {
    let name: String
    let size: String
    enum CodingKeys: String, CodingKey { case name = "Name", size = "Size" }
}
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter DockerDiskUsage 2>&1 | grep -E "✘|Test run" | head -5
```

Expected: 7 条全 PASS。

- [ ] **Step 6: 变异验证**

两次变异：

1. 去掉镜像 ID 的短化（`images[entry.id] = entry.size`）→ `indexesImageSizesByShortID` 应变红。
2. 去掉 `guard trimmed.hasPrefix("{")` → `tableOutputReturnsNil` 应变红。

还原后 `git diff` 确认无残留。

- [ ] **Step 7: 构建 + lint + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
cd /Users/crazyball/Code/Swift/Conn && git add -A && git commit -m "feat(ops): docker system df -v 占用索引，格式不支持时安全降级

这条命令输出格式跨 docker 版本不稳，老版本不支持 --format json 会吐表格文本。
解析器遇到非 JSON 一律返回 nil，让上层显示「—」而不是崩或给出错误数字。
镜像 ID 归一化成 12 位短 ID —— system df 给带 sha256: 的长 ID，
docker images 给短 ID，不归一化永远查不到。"
```

---

### Task 4: DockerService 取数函数

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerService.swift`
- Test: `Packages/ConnPackages/Tests/ConnOpsTests/DockerServiceResourceTests.swift`（新建）

**Interfaces:**
- Consumes: Task 1–3 的全部命令与解析函数。
- Produces（全部 `public static`，与现有 `listImages(on:sudo:)` 同构）：
  - `listVolumes(on:sudo:) async throws -> [VolumeInfo]`
  - `danglingVolumeNames(on:sudo:) async throws -> Set<String>`
  - `volumeDetail(name:on:sudo:) async throws -> VolumeDetail?`
  - `listNetworks(on:sudo:) async throws -> [NetworkInfo]`
  - `danglingNetworkNames(on:sudo:) async throws -> Set<String>`
  - `networkDetail(name:on:sudo:) async throws -> NetworkDetail?`
  - `imageDetail(reference:on:sudo:) async throws -> ImageDetail?`
  - `imageHistory(reference:on:sudo:) async throws -> [ImageLayer]`
  - `diskUsage(on:sudo:) async throws -> DockerDiskUsage?`
  - `containersUsingVolume(name:on:sudo:) async throws -> [ContainerInfo]`

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnOpsTests/DockerServiceResourceTests.swift`。用
`MockSSHTransport` 的 `commandResponses` 精确按命令串喂输出：

```swift
import ConnSSH
import Testing
@testable import ConnOps

@Suite("DockerService — 卷 / 网络 / 镜像详情取数")
struct DockerServiceResourceTests {
    private func session(_ responses: [String: String]) async throws -> any SSHSession {
        let mapped = responses.mapValues { MockSSHTransport.CommandResponse(stdout: $0) }
        let transport = MockSSHTransport(behavior: .init(commandResponses: mapped))
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
        let detail = try #require(try await DockerService.networkDetail(name: "web", on: session, sudo: false))
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
            DockerCommand.imageHistory(reference: "nginx:1.25", sudo: false): history,
        ])
        let detail = try #require(
            try await DockerService.imageDetail(reference: "nginx:1.25", on: session, sudo: false)
        )
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

    @Test("反查引用某卷的容器")
    func containersUsingVolume() async throws {
        let json = """
        {"ID":"c1","Image":"pg:16","Names":"pg-main","State":"running","Status":"Up 2 days","Ports":""}
        """
        let session = try await session([
            DockerCommand.containersUsingVolume(name: "pgdata", sudo: false): json,
        ])
        let hits = try await DockerService.containersUsingVolume(name: "pgdata", on: session, sudo: false)
        #expect(hits.map(\.name) == ["pg-main"])
    }
}
```

> 若 `MockSSHTransport.Behavior` 的 `commandResponses` 字段名与上面不符，
> 以 `Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift` 的实际
> 定义为准调整，**不要改 Mock 去迁就测试**。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter DockerServiceResource 2>&1 | grep -E "error:|✘|Test run" | head -5
```

Expected: 编译失败 —— 各取数函数与 `DockerCommand.containersUsingVolume` 不存在。

- [ ] **Step 3: 补一条命令**

`DockerCommand.swift` 卷区末尾加：

```swift
    /// 引用某个卷的容器（含已停止的——它引用着就删不掉该卷）。
    public static func containersUsingVolume(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker ps -a --filter volume=\(name) --format '{{json .}}'"
    }
```

- [ ] **Step 4: 加取数函数**

`DockerService.swift` 的 `logStream` 之前插入：

```swift
    // MARK: - 卷

    public static func listVolumes(on session: any SSHSession, sudo: Bool) async throws -> [VolumeInfo] {
        let result = try await session.exec(DockerCommand.volumes(sudo: sudo))
        return DockerParser.parseVolumes(result.stdoutText)
    }

    public static func danglingVolumeNames(on session: any SSHSession, sudo: Bool) async throws -> Set<String> {
        let result = try await session.exec(DockerCommand.danglingVolumes(sudo: sudo))
        return DockerParser.parseNameList(result.stdoutText)
    }

    public static func volumeDetail(
        name: String, on session: any SSHSession, sudo: Bool
    ) async throws -> VolumeDetail? {
        let result = try await session.exec(DockerCommand.volumeInspect(name: name, sudo: sudo))
        return DockerParser.parseVolumeInspect(result.stdoutText)
    }

    /// 引用某卷的容器。含已停止的——它引用着就删不掉该卷。
    public static func containersUsingVolume(
        name: String, on session: any SSHSession, sudo: Bool
    ) async throws -> [ContainerInfo] {
        let result = try await session.exec(DockerCommand.containersUsingVolume(name: name, sudo: sudo))
        return DockerParser.parsePS(result.stdoutText)
    }

    // MARK: - 网络

    public static func listNetworks(on session: any SSHSession, sudo: Bool) async throws -> [NetworkInfo] {
        let result = try await session.exec(DockerCommand.networks(sudo: sudo))
        return DockerParser.parseNetworks(result.stdoutText)
    }

    public static func danglingNetworkNames(on session: any SSHSession, sudo: Bool) async throws -> Set<String> {
        let result = try await session.exec(DockerCommand.danglingNetworks(sudo: sudo))
        return DockerParser.parseNameList(result.stdoutText)
    }

    public static func networkDetail(
        name: String, on session: any SSHSession, sudo: Bool
    ) async throws -> NetworkDetail? {
        let result = try await session.exec(DockerCommand.networkInspect(name: name, sudo: sudo))
        return DockerParser.parseNetworkInspect(result.stdoutText)
    }

    // MARK: - 镜像详情

    public static func imageDetail(
        reference: String, on session: any SSHSession, sudo: Bool
    ) async throws -> ImageDetail? {
        let result = try await session.exec(DockerCommand.imageInspect(reference: reference, sudo: sudo))
        return DockerParser.parseImageInspect(result.stdoutText)
    }

    public static func imageHistory(
        reference: String, on session: any SSHSession, sudo: Bool
    ) async throws -> [ImageLayer] {
        let result = try await session.exec(DockerCommand.imageHistory(reference: reference, sudo: sudo))
        return DockerParser.parseImageHistory(result.stdoutText)
    }

    // MARK: - 磁盘占用

    /// 磁盘占用。**格式不支持时返回 nil 而不抛错**——它只是锦上添花的字段，
    /// 抛错会让调用方以为整页坏了。
    public static func diskUsage(on session: any SSHSession, sudo: Bool) async throws -> DockerDiskUsage? {
        let result = try await session.exec(DockerCommand.diskUsage(sudo: sudo), timeout: .seconds(30))
        return DockerParser.parseDiskUsage(result.stdoutText)
    }
```

`DockerParser.parsePS` 目前是 `internal`，`DockerService` 同模块可直接用，无需改可见性。

- [ ] **Step 5: 跑测试确认通过 + 全量**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test --filter DockerServiceResource 2>&1 | grep -E "✘|Test run" | head -5
swift test 2>&1 | grep -E "✘|Test run with" | tail -2
```

Expected: 7 条全 PASS；全量无红。

- [ ] **Step 6: 构建 + lint + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
cd /Users/crazyball/Code/Swift/Conn && git add -A && git commit -m "feat(ops): DockerService 补卷 / 网络 / 镜像详情 / 磁盘占用取数

diskUsage 格式不支持时返回 nil 而不抛错——它只是锦上添花的字段，
抛错会让调用方以为整页坏了。"
```

---

### Task 5: 拆分 DockerViewModel（纯重构，行为不变）

**Files:**
- Create: `Conn/Conn/Hosts/DockerContainersModel.swift`
- Create: `Conn/Conn/Hosts/DockerImagesModel.swift`
- Modify: `Conn/Conn/Hosts/DockerViewModel.swift`
- Modify: `Conn/Conn/Hosts/DockerView.swift`（引用改名）
- Modify: `Conn/Conn/Hosts/ContainerDetailView.swift`、`Conn/Conn/Hosts/ContainerCard.swift`（若引用了被搬走的成员）

**Interfaces:**
- Consumes: 现有 `DockerService` 全部函数。
- Produces:
  - `DockerViewModel`：保留 `loadState` / `hasLoaded` / `usesSudo` / `actionMessage` / `loadIfNeeded()` / `load()`，新增 `containers: DockerContainersModel`、`images: DockerImagesModel` 两个子模型属性，以及供子模型取会话用的 `session() async throws -> any SSHSession`。
  - `DockerContainersModel`：`items` / `busyContainerID` / `pendingRemoval` / `refresh()` / `perform(_:on:)` / `requestRemoval(_:)` / `confirmRemoval()` / `detail(for:)` / `consoleCommand(for:)`
  - `DockerImagesModel`：`items` / `loaded` / `error` / `busyImageID` / `pendingRemoval` / `loadIfNeeded()` / `load()` / `requestRemoval(_:)` / `confirmRemoval()` / `prune()`

**这是纯重构：外部可见行为一个都不能变。** 本任务不加任何新功能——把新资源
塞进一个已经 197 行的模型会让 Task 6 无从下手，所以先把地基理顺。

- [ ] **Step 1: 记录重构前的行为基线**

```bash
cd /Users/crazyball/Code/Swift/Conn && grep -rn "viewModel\." Conn/Conn/Hosts/DockerView.swift Conn/Conn/Hosts/ContainerDetailView.swift Conn/Conn/Hosts/ContainerCard.swift > /tmp/docker-vm-usage-before.txt
wc -l /tmp/docker-vm-usage-before.txt
```

这份清单是重构的验收依据：每一行都要在重构后有对应去处，不能悄悄少掉一个功能。

- [ ] **Step 2: 抽出容器模型**

新建 `Conn/Conn/Hosts/DockerContainersModel.swift`。**逐字搬运** `DockerViewModel`
里 `containers` / `busyContainerID` / `pendingRemoval` / `refreshContainers` /
`perform` / `requestRemoval` / `confirmRemoval` / `detail(for:)` /
`consoleCommand(for:)` 的实现，只改三处：

- 类型名 `DockerViewModel` → `DockerContainersModel`
- `containers` 属性改名 `items`
- 取会话与 sudo 改为经构造注入的闭包，避免子模型各自持有 `ConnectionManager`

```swift
import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 容器列表与动作。
///
/// 从 `DockerViewModel` 拆出：那个类型原本同时管可用性探测、容器、镜像、
/// 动作与弹窗，再塞进卷与网络会奔着 500 行去，四类资源的加载状态也互相纠缠。
@Observable
@MainActor
final class DockerContainersModel {
    private(set) var items: [ContainerInfo] = []
    /// 正在执行操作的容器 id（禁用该行按钮 + 显示忙碌）。
    private(set) var busyContainerID: String?
    /// 待确认删除的容器（rm 强确认，方案 §4.4）。
    var pendingRemoval: ContainerInfo?

    private let context: DockerContext

    init(context: DockerContext) {
        self.context = context
    }

    func load() async throws {
        items = try await DockerService.list(on: context.session(), sudo: context.sudo)
    }

    /// 下拉刷新：静默重拉，不切加载态——保留列表、避免闪烁。
    /// 失败时保留上次结果，仅弹提示。
    func refresh() async {
        do {
            try await load()
        } catch {
            context.report(String(format: L("%@ 失败：%@"), L("刷新"), error.friendlyDiagnosis))
        }
    }

    func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        busyContainerID = container.id
        defer { busyContainerID = nil }
        do {
            let result = try await DockerService.perform(
                action, id: container.id, on: context.session(), sudo: context.sudo
            )
            context.audit(command: "docker \(action.verb) \(container.name)", result: result)
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            context.report(result.isSuccess
                ? String(format: L("%@ %@ 成功"), action.label, container.name)
                : String(format: L("%@ %@ 失败：%@"), action.label, container.name, detail))
            await refresh()
        } catch {
            context.report(String(format: L("%@ 失败：%@"), action.label, error.friendlyDiagnosis))
        }
    }

    func requestRemoval(_ container: ContainerInfo) {
        pendingRemoval = container
    }

    func confirmRemoval() async {
        guard let container = pendingRemoval else { return }
        pendingRemoval = nil
        await perform(.remove, on: container)
    }

    /// 容器详情（inspect）——供详情页加载。
    func detail(for container: ContainerInfo) async -> ContainerDetail? {
        do {
            return try await DockerService.inspect(
                id: container.id, on: context.session(), sudo: context.sudo
            )
        } catch {
            return nil
        }
    }

    /// 进入容器控制台的命令（PTY 里 exec）。
    func consoleCommand(for container: ContainerInfo) -> String {
        DockerCommand.console(id: container.id, sudo: context.sudo)
    }
}
```

- [ ] **Step 3: 建共享上下文**

同文件顶部（或新建 `Conn/Conn/Hosts/DockerContext.swift`，二选一，本计划选后者）
新建 `Conn/Conn/Hosts/DockerContext.swift`：

```swift
import ConnKit
import ConnOps
import ConnSSH
import Foundation

/// 四个资源模型共享的依赖：取会话、当前是否需 sudo、上报结果、写审计。
///
/// 用一个轻量上下文而不是让每个子模型各自持有 `ConnectionManager` + `Host` +
/// `RunHistoryRepository`：sudo 标志由可用性探测决定、只有外壳知道，
/// 子模型每次都要用它，靠构造注入传三四个参数会很啰嗦且容易漏。
@MainActor
struct DockerContext {
    let session: () async throws -> any SSHSession
    /// 当前是否需 sudo -n 前缀。由可用性探测决定。
    var sudo: Bool
    /// 上报一条给用户看的结果（外壳统一弹 alert）。
    let report: (String) -> Void
    /// 写运行审计。
    let audit: (String, ExecResult) -> Void
}
```

> `sudo` 是 `var`：探测在 `load()` 里完成，晚于上下文构造，外壳要回填。

- [ ] **Step 4: 抽出镜像模型**

新建 `Conn/Conn/Hosts/DockerImagesModel.swift`，同样逐字搬运镜像相关实现：

```swift
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
```

- [ ] **Step 5: 外壳瘦身**

`DockerViewModel.swift` 整体替换为：

```swift
import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Observation

/// Docker 分段外壳：可用性探测、sudo 标志、共用的结果提示，以及四个资源模型。
///
/// 它**不再直接持有任何资源列表**——容器、镜像、卷、网络各自一个模型，
/// 各管各的加载与状态。这样加第五类资源时只多一个文件，不动这里。
@Observable
@MainActor
final class DockerViewModel {
    enum LoadState: Equatable {
        case loading
        case unavailable(DockerAvailability)
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    /// 首次加载后置真——切换分段时不再自动重拉（改下拉刷新）。
    private(set) var hasLoaded = false
    var actionMessage: String?

    private(set) var containers: DockerContainersModel!
    private(set) var images: DockerImagesModel!

    private let host: Host
    private let connectionManager: ConnectionManager
    private let runHistory: any RunHistoryRepository
    private var availability: DockerAvailability = .notInstalled
    private var context: DockerContext!

    init(host: Host, dependencies: AppDependencies) {
        self.host = host
        connectionManager = dependencies.connectionManager
        runHistory = dependencies.runHistory
        let manager = dependencies.connectionManager
        let currentHost = host
        context = DockerContext(
            session: { try await manager.session(for: currentHost) },
            sudo: false,
            report: { [weak self] message in self?.actionMessage = message },
            audit: { [weak self] command, result in self?.audit(command: command, result: result) }
        )
        containers = DockerContainersModel(context: context)
        images = DockerImagesModel(context: context)
    }

    /// 当前是否需 sudo（供容器日志沿用同一提权）。
    var usesSudo: Bool { availability.sudo }

    /// 仅首次加载（分段出现时调用）。已加载则跳过。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        hasLoaded = true
        loadState = .loading
        do {
            let session = try await connectionManager.session(for: host)
            let probe = try await DockerService.probe(on: session)
            availability = probe
            guard probe.isUsable else {
                loadState = .unavailable(probe)
                return
            }
            // 探测晚于上下文构造，sudo 标志要回填给全部子模型
            propagateSudo(probe.sudo)
            try await containers.load()
            loadState = .ready
        } catch {
            loadState = .failed(error.friendlyDiagnosis)
        }
    }

    private func propagateSudo(_ sudo: Bool) {
        context.sudo = sudo
        containers = DockerContainersModel(context: context)
        images = DockerImagesModel(context: context)
    }

    private func audit(command: String, result: ExecResult) {
        try? runHistory.record(RunHistoryEntry(
            hostUUID: host.id,
            command: command,
            exitCode: result.exitCode,
            outputHead: String(result.stdoutText.prefix(500))
        ))
    }
}
```

> **`propagateSudo` 重建子模型会丢掉已加载的列表**——探测发生在任何列表加载
> 之前，所以此刻丢的是空列表，无害。但这条约束必须写成注释，否则将来有人在
> 探测后调用它就会莫名清空用户正在看的数据。**实现时请在该方法上加注释说明。**

- [ ] **Step 6: 改调用点**

按 Step 1 的清单逐条改：`viewModel.containers` → `viewModel.containers.items`、
`viewModel.refreshContainers()` → `viewModel.containers.refresh()`、
`viewModel.images` → `viewModel.images.items`、
`viewModel.pendingRemoval` → `viewModel.containers.pendingRemoval`、
`viewModel.pendingImageRemoval` → `viewModel.images.pendingRemoval`、
`viewModel.loadImagesIfNeeded()` → `viewModel.images.loadIfNeeded()`，
`viewModel.pruneImages()` → `viewModel.images.prune()`，以此类推。

- [ ] **Step 7: 验证行为未变**

```bash
cd /Users/crazyball/Code/Swift/Conn && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD" | head -5
cd Packages/ConnPackages && swift test 2>&1 | grep -E "✘|Test run with" | tail -2
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

截图对比重构前后的 Docker 两个分段，确认视觉与交互一致：

```bash
cd /Users/crazyball/Code/Swift/Conn
DEV=EAA9BFB6-2D92-4831-9CFE-005A20FE35C4
APP=$(ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$DEV" "$APP"; xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_CONN_DEMO=1 SIMCTL_CHILD_CONN_SMOKE_DETAIL=1 SIMCTL_CHILD_CONN_SMOKE_SEGMENT=docker xcrun simctl launch "$DEV" "$BUNDLE"
sleep 6; xcrun simctl io "$DEV" screenshot /tmp/docker-after-refactor.png
```

用 Read 工具打开截图，确认容器列表、状态徽标、操作按钮与重构前一致。

- [ ] **Step 8: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn && git add -A && git commit -m "refactor: DockerViewModel 拆成外壳 + 容器 / 镜像两个资源模型

纯重构，外部行为不变。原类型同时管可用性探测、容器、镜像、动作与弹窗，
再塞进卷与网络会奔着 500 行去，四类资源的加载状态也互相纠缠。
拆后外壳只留探测、sudo、共用提示；加第五类资源时只多一个文件。

子模型共享一个 DockerContext（取会话 / sudo / 上报 / 审计），
而不是各自持有 ConnectionManager + Host + RunHistoryRepository。"
```

---

### Task 6: 卷与网络的模型、视图与四项分段

**Files:**
- Create: `Conn/Conn/Hosts/DockerVolumesModel.swift`
- Create: `Conn/Conn/Hosts/DockerNetworksModel.swift`
- Create: `Conn/Conn/Hosts/VolumeDetailView.swift`
- Create: `Conn/Conn/Hosts/NetworkDetailView.swift`
- Modify: `Conn/Conn/Hosts/DockerView.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 4 的取数函数、Task 5 的 `DockerContext`。
- Produces:
  - `DockerVolumesModel`：`items` / `loaded` / `error` / `unusedNames: Set<String>` / `loadIfNeeded()` / `load()` / `detail(for:) async -> VolumeDetail?` / `containersUsing(_:) async -> [ContainerInfo]`
  - `DockerNetworksModel`：`items` / `loaded` / `error` / `unusedNames: Set<String>` / `loadIfNeeded()` / `load()` / `detail(for:) async -> NetworkDetail?`
  - `DockerView.Tab` 增 `.volumes` / `.networks`

- [ ] **Step 1: 卷模型**

新建 `Conn/Conn/Hosts/DockerVolumesModel.swift`：

```swift
import ConnOps
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

    func load() async {
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
```

- [ ] **Step 2: 网络模型**

新建 `Conn/Conn/Hosts/DockerNetworksModel.swift`：

```swift
import ConnOps
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

    func load() async {
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
```

- [ ] **Step 3: 外壳挂上两个新模型**

`DockerViewModel.swift` 里：属性区加 `private(set) var volumes: DockerVolumesModel!`
与 `private(set) var networks: DockerNetworksModel!`；`init` 与 `propagateSudo`
里一并构造。

- [ ] **Step 4: 分段扩到四项**

`DockerView.swift` 的 `Tab` 改成：

```swift
    enum Tab: String, CaseIterable, Identifiable {
        case containers = "容器"
        case images = "镜像"
        case volumes = "卷"
        case networks = "网络"
        var id: String { rawValue }
    }
```

`Picker` 的 `ForEach` 与 `switch tab` 各补两个分支；`refresh(for:)` 与
`loadIfNeeded` 的 `switch` 同步补。

- [ ] **Step 5: 先抽出共享详情构件**

`section(_:content:)` 与 `infoRows(_:)` 现在是 `ContainerDetailView` 的**私有**方法
（`ContainerDetailView.swift:197` 与 `:209`）。三个新详情页都要用它们，照抄三份
就是逐字重复。先抽出来：

新建 `Conn/Conn/Hosts/DockerDetailBuilding.swift`：

```swift
import ConnUI
import SwiftUI

/// Docker 各详情页共用的版式构件。
///
/// 从 `ContainerDetailView` 的私有方法抽出——卷、网络、镜像三个详情页要用同一套
/// 版式，照抄三份就是四份会各自漂移的重复。
enum DockerDetail {
    /// 带眉标的分组卡片。
    @ViewBuilder
    static func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(title).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            VStack(alignment: .leading, spacing: ConnSpacing.sm) {
                content()
            }
            .padding(ConnSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    /// 左标签右取值的键值行组，行间细分隔线。
    static func infoRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                HStack(spacing: ConnSpacing.sm) {
                    Text(row.0).font(.connSubheadline).foregroundStyle(.connMuted)
                    Spacer()
                    Text(row.1).font(.connData()).connTabularNumbers().foregroundStyle(.connInk)
                        .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.vertical, ConnSpacing.sm)
            }
        }
    }

    /// 可点的容器行。三个详情页的「引用/接入容器」段共用。
    static func containerRow(name: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "shippingbox").font(.system(size: 11))
                    .foregroundStyle(.connMuted).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.connData(.caption2)).foregroundStyle(.connInk)
                    if let subtitle {
                        Text(subtitle).font(.connData(.caption2)).foregroundStyle(.connMuted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.connMuted)
            }
            .padding(.vertical, ConnSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    /// 「没有容器在用」的空态 + 未使用徽标。
    static func unusedNotice(_ text: String) -> some View {
        HStack(spacing: ConnSpacing.xs) {
            StatusPill(L("未使用"), semantic: .warn)
            Text(text).font(.connFootnote).foregroundStyle(.connMuted)
        }
    }
}
```

改 `ContainerDetailView`：删掉它自己的 `section` 与 `infoRows`，调用处改成
`DockerDetail.section(...)` / `DockerDetail.infoRows(...)`。**这一步不改任何行为**，
改完先构建一次确认容器详情页视觉无变化。

- [ ] **Step 6: 卷详情页**

新建 `Conn/Conn/Hosts/VolumeDetailView.swift`：

```swift
import ConnOps
import ConnUI
import SwiftUI

/// 卷详情：inspect 信息 + 哪些容器在引用它。
struct VolumeDetailView: View {
    let volume: VolumeInfo
    let model: DockerVolumesModel
    /// 磁盘占用查不到时显示「—」——这条信息由 `docker system df -v` 单独异步取，
    /// 它失败不该让本页看起来坏了。
    let size: String?
    /// 点容器行时的跳转回调，由 `DockerView` 注入路由。
    let onOpenContainer: (ContainerInfo) -> Void

    @State private var detail: VolumeDetail?
    @State private var users: [ContainerInfo] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
                    summary
                    usersSection
                    if let detail, !detail.labels.isEmpty {
                        DockerDetail.section(L("标签")) { keyValues(detail.labels) }
                    }
                    if let detail, !detail.options.isEmpty {
                        DockerDetail.section(L("选项")) { keyValues(detail.options) }
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(volume.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
                (L("驱动"), volume.driver),
                (L("作用域"), volume.scope),
                (L("大小"), size ?? "—"),
                (L("创建"), detail?.createdAt ?? "—"),
                (L("挂载点"), detail?.mountpoint ?? volume.mountpoint)
            ])
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        DockerDetail.section(L("引用容器")) {
            if users.isEmpty {
                DockerDetail.unusedNotice(L("没有容器引用此卷"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(users.enumerated()), id: \.offset) { index, container in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: container.name, subtitle: container.image
                        ) { onOpenContainer(container) }
                    }
                }
            }
        }
    }

    private func keyValues(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).font(.connData(.caption2)).foregroundStyle(.connInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        // 两条并行：详情与引用查询互不依赖
        async let detailTask = model.detail(for: volume)
        async let usersTask = model.containersUsing(volume)
        detail = await detailTask
        users = await usersTask
        loading = false
    }
}
```

- [ ] **Step 7: 网络详情页**

新建 `Conn/Conn/Hosts/NetworkDetailView.swift`：

```swift
import ConnOps
import ConnUI
import SwiftUI

/// 网络详情：inspect 信息 + 接入的容器。
///
/// 接入容器由 `docker network inspect` 直接给出，**不需要额外命令**——
/// 这是三类资源里唯一免费的反向关联。
struct NetworkDetailView: View {
    let network: NetworkInfo
    let model: DockerNetworksModel
    let onOpenContainer: (String) -> Void

    @State private var detail: NetworkDetail?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                if network.isPredefined {
                    HStack(spacing: ConnSpacing.xs) {
                        StatusPill(L("预置"), semantic: .info)
                        Text(L("Docker 预置，不可删除")).font(.connFootnote).foregroundStyle(.connMuted)
                    }
                }
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
                    summary
                    attachedSection
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(network.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detail = await model.detail(for: network)
            loading = false
        }
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
                (L("网络 ID"), String(network.id.prefix(12))),
                (L("驱动"), network.driver),
                (L("作用域"), network.scope),
                (L("子网"), detail?.subnet ?? "—"),
                (L("网关"), detail?.gateway ?? "—"),
                (L("内部网络"), (detail?.isInternal ?? false) ? L("是") : L("否"))
            ])
        }
    }

    @ViewBuilder
    private var attachedSection: some View {
        DockerDetail.section(L("接入容器")) {
            let containers = detail?.attachedContainers ?? []
            if containers.isEmpty {
                DockerDetail.unusedNotice(L("没有容器接入此网络"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.offset) { index, attached in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: attached.name, subtitle: attached.ipv4
                        ) { onOpenContainer(attached.id) }
                    }
                }
            }
        }
    }
}
```

> `NetworkDetail.AttachedContainer` 只有 id / name / ipv4，**不是完整的
> `ContainerInfo`**，所以跳转回调传的是容器 id，由 `DockerView` 到容器列表里
> 按 id 找出对应的 `ContainerInfo` 再跳。找不到（容器已被删）时不跳转。

- [ ] **Step 8: 补五语文案**

新增文案键（zh-Hans 源串）：`卷`、`网络`、`挂载点`、`驱动`、`作用域`、`子网`、
`网关`、`内部网络`、`引用容器`、`接入容器`、`未使用`、`没有容器引用此卷`、
`没有容器接入此网络`、`标签`、`选项`、`Docker 预置，不可删除`。

每个键补 en / ja / ko / zh-Hant 四语，写进 `Conn/Conn/Localizable.xcstrings`。

- [ ] **Step 9: 构建 + 截图 + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD" | head -5
cd Tooling && swiftlint lint --quiet | wc -l
```

截图四个分段（Task 8 会补演示数据，本步若卷/网络为空属预期，记录即可）。提交：

```bash
git add -A && git commit -m "feat: Docker 分段扩到四项，补卷与网络的列表与详情

卷的「未使用」直接用 dangling；网络的 dangling 会包含预置的 bridge/host/none，
按 isPredefined 滤掉——它们永远删不掉，打徽标只是噪声。
网络的接入容器由 inspect 直接给出，零额外命令；卷的引用容器只在打开详情时才查。"
```

---

### Task 7: 镜像详情页、磁盘占用接入与四列表搜索

**Files:**
- Create: `Conn/Conn/Hosts/ImageDetailView.swift`
- Modify: `Conn/Conn/Hosts/DockerImagesModel.swift`
- Modify: `Conn/Conn/Hosts/DockerViewModel.swift`
- Modify: `Conn/Conn/Hosts/DockerView.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 2–4 的镜像详情 / 层历史 / 磁盘占用取数；Task 6 的四项分段。
- Produces:
  - `DockerImagesModel` 增：`unusedIDs: Set<String>`、`detail(for:) async -> ImageDetail?`、`history(for:) async -> [ImageLayer]`
  - `DockerViewModel` 增：`diskUsage: DockerDiskUsage?`、`loadDiskUsage() async`

- [ ] **Step 1: 镜像模型补未使用判定与详情**

`DockerImagesModel` 加：

```swift
    /// 没有任何容器引用的镜像 id。由容器列表反查——不能用 docker 的 dangling，
    /// 那是「无 tag」，与「没被引用」是两码事。
    private(set) var unusedIDs: Set<String> = []

    /// 用容器列表刷新「未使用」判定。容器段本来就要拉 ps -a，不额外跑命令。
    func refreshUsage(containers: [ContainerInfo]) {
        unusedIDs = ImageUsage.unusedImageIDs(images: items, containers: containers)
    }

    func detail(for image: ImageInfo) async -> ImageDetail? {
        try? await DockerService.imageDetail(
            reference: image.reference, on: context.session(), sudo: context.sudo
        )
    }

    func history(for image: ImageInfo) async -> [ImageLayer] {
        (try? await DockerService.imageHistory(
            reference: image.reference, on: context.session(), sudo: context.sudo
        )) ?? []
    }
```

**不要改 `load()` 的签名**：`loadIfNeeded()` 调的是无参 `load()`，加参数会把它一起
带断。判定所需的容器列表由**外壳**在两边都就绪后推给镜像模型：

`DockerViewModel` 里加一个协调方法，镜像分段出现时调它而不是直接调
`images.loadIfNeeded()`：

```swift
    /// 加载镜像并刷新「未使用」判定。
    ///
    /// 判定要拿容器列表比对，而容器可能还没加载过（用户直接点进镜像分段）。
    /// 所以这里保证两边都就绪——多跑一次 `docker ps -a` 也值，
    /// 否则「未使用」会全量误报成「都没在用」，用户据此删镜像就是事故。
    func loadImagesWithUsage() async {
        await images.loadIfNeeded()
        if containers.items.isEmpty {
            try? await containers.load()
        }
        images.refreshUsage(containers: containers.items)
    }
```

`DockerView` 的镜像分段 `.task` 改调 `viewModel.loadImagesWithUsage()`；
下拉刷新同理。

- [ ] **Step 2: 外壳补磁盘占用**

`DockerViewModel` 加：

```swift
    /// 磁盘占用。**独立于列表加载**——这条命令在大主机上要数秒且格式跨版本不稳，
    /// 失败时保持 nil，UI 显示「—」，**不弹错误**：它只是锦上添花的信息，
    /// 不该让整个页面看起来坏了。
    private(set) var diskUsage: DockerDiskUsage?

    func loadDiskUsage() async {
        guard case .ready = loadState else { return }
        diskUsage = try? await DockerService.diskUsage(
            on: connectionManager.session(for: host), sudo: availability.sudo
        )
    }
```

镜像与卷分段出现时用 `.task { await viewModel.loadDiskUsage() }` 触发，与列表加载
并行，不 await 在列表之前。

- [ ] **Step 3: 镜像详情页**

新建 `Conn/Conn/Hosts/ImageDetailView.swift`（复用 Task 6 Step 5 抽出的
`DockerDetail` 构件）：

```swift
import ConnOps
import ConnUI
import SwiftUI

/// 镜像详情：inspect 信息 + 层历史 + 哪些容器在用它。
struct ImageDetailView: View {
    let image: ImageInfo
    let model: DockerImagesModel
    /// 引用该镜像的容器。由调用方用容器列表算好传入——判定是纯函数，
    /// 不该让视图自己去取数。
    let users: [ContainerInfo]
    /// 来自 `docker system df -v`，查不到为 nil，显示时回退到 `ImageInfo.size`。
    let diskSize: String?
    let onOpenContainer: (ContainerInfo) -> Void

    @State private var detail: ImageDetail?
    @State private var layers: [ImageLayer] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                if loading {
                    ProgressView(L("读取详情…")).font(.connFootnote).foregroundStyle(.connMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ConnSpacing.xl)
                } else {
                    summary
                    usersSection
                    layersSection
                    if let detail {
                        commandSection(detail)
                        listSection(L("环境变量"), detail.env)
                        listSection(L("标签"), detail.labels)
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(image.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            DockerDetail.infoRows([
                (L("标签"), detail.map { $0.tags.isEmpty ? "—" : $0.tags.joined(separator: ", ") } ?? image.displayName),
                (L("镜像 ID"), detail?.id ?? image.imageID),
                (L("大小"), diskSize ?? image.size),
                (L("架构"), [detail?.os, detail?.architecture].compactMap { $0 }.joined(separator: "/")),
                (L("创建于"), detail?.created ?? image.created),
                (L("摘要"), detail?.digest ?? "—")
            ])
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        DockerDetail.section(L("引用容器")) {
            if users.isEmpty {
                DockerDetail.unusedNotice(L("没有容器使用此镜像"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(users.enumerated()), id: \.offset) { index, container in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        DockerDetail.containerRow(
                            name: container.name, subtitle: container.status
                        ) { onOpenContainer(container) }
                    }
                }
            }
        }
    }

    /// 层历史。指令可能很长，限 3 行——手机上完整指令没法读，
    /// 真要看全的用 textSelection 复制出去。
    @ViewBuilder
    private var layersSection: some View {
        if !layers.isEmpty {
            DockerDetail.section(L("层历史")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { index, layer in
                        if index > 0 { Rectangle().fill(Color.connLine).frame(height: 0.5) }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(layer.size).font(.connData(.caption2))
                                    .connTabularNumbers().foregroundStyle(.connInk)
                                Spacer()
                                Text(layer.createdSince).font(.connData(.caption2))
                                    .foregroundStyle(.connMuted)
                            }
                            Text(layer.createdBy).font(.connData(.caption2))
                                .foregroundStyle(.connMuted).lineLimit(3)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, ConnSpacing.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commandSection(_ detail: ImageDetail) -> some View {
        if detail.entrypoint != nil || detail.command != nil {
            DockerDetail.section(L("入口与命令")) {
                DockerDetail.infoRows([
                    (L("入口"), detail.entrypoint ?? "—"),
                    (L("命令"), detail.command ?? "—")
                ])
            }
        }
    }

    @ViewBuilder
    private func listSection(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            DockerDetail.section(title) {
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item).font(.connData(.caption2)).foregroundStyle(.connInk)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func load() async {
        // 两条并行：详情与层历史互不依赖
        async let detailTask = model.detail(for: image)
        async let layersTask = model.history(for: image)
        detail = await detailTask
        layers = await layersTask
        loading = false
    }
}
```

- [ ] **Step 4: 四个列表接搜索框**

`DockerView.swift` 里每个分段的列表上方加 `ConnSearchField`（`ConnUI` 提供，
高度固定 38pt）。四个分段共用一个搜索词状态——**切分段时清空**，否则用户会
看到「明明有卷却一个都不显示」，因为上一个分段的搜索词还在生效：

```swift
    @State private var search = ""

    // 分段切换时清空搜索词，避免上一分段的过滤条件悄悄套在新分段上
    .onChange(of: tab) { _, _ in search = "" }
```

过滤是纯本地的，不触发任何命令。四条规则：

```swift
    private var filteredContainers: [ContainerInfo] {
        guard !search.isEmpty else { return viewModel.containers.items }
        return viewModel.containers.items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.image.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredImages: [ImageInfo] {
        guard !search.isEmpty else { return viewModel.images.items }
        return viewModel.images.items.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    private var filteredVolumes: [VolumeInfo] {
        guard !search.isEmpty else { return viewModel.volumes.items }
        return viewModel.volumes.items.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var filteredNetworks: [NetworkInfo] {
        guard !search.isEmpty else { return viewModel.networks.items }
        return viewModel.networks.items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.driver.localizedCaseInsensitiveContains(search)
        }
    }
```

搜索框的 prompt 按分段取：`L("搜索容器")` / `L("搜索镜像")` / `L("搜索卷")` /
`L("搜索网络")`。

- [ ] **Step 5: 补五语文案**

新增键：`层历史`、`引用容器`（已有则复用）、`没有容器使用此镜像`、`架构`、
`创建于`、`摘要`、`入口`、`命令`、`环境变量`、`大小`、`搜索容器`、`搜索镜像`、
`搜索卷`、`搜索网络`。四语齐补。

- [ ] **Step 6: 构建 + lint + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD" | head -5
cd Tooling && swiftlint lint --quiet | wc -l
git add -A && git commit -m "feat: 镜像详情页（含层历史）、磁盘占用与四列表搜索

磁盘占用独立于列表加载：命令在大主机上要数秒且格式跨版本不稳，
失败时保持 nil、UI 显示「—」且不弹错误——它只是锦上添花的信息。
镜像的「未使用」由容器列表反查得出，容器段本来就要拉 ps -a，不额外跑命令。"
```

---

### Task 8: 交叉跳转、演示数据与截图验收

**Files:**
- Modify: `Conn/Conn/Hosts/DockerView.swift`（路由）
- Modify: `Conn/Conn/Hosts/ContainerDetailView.swift`（挂载与网络可点）
- Modify: `Conn/Conn/Demo/DemoOps.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 6–7 的全部视图与模型。
- Produces: 无对外接口。

- [ ] **Step 1: 路由扩展**

`DockerView.Route` 增 `case imageDetail(ImageInfo)`、`case volumeDetail(VolumeInfo)`、
`case networkDetail(NetworkInfo)`，`destination` 与 `id` 同步补。

- [ ] **Step 2: 容器详情 → 卷 / 网络**

`ContainerDetailView` 里 `mounts` 与 `networks` 两段的每一行改为可点：
挂载行按卷名跳 `volumeDetail`，网络行按网络名跳 `networkDetail`。

**注意** `ContainerDetail.mounts` 现在是拼好的展示串（`"源 → 目标"`），
拿不到纯卷名。需要在 `ContainerDetail` 增一个 `mountSources: [String]`
（`InspectMount.name` 优先，回退 `source`），解析器同步补，并**补一条解析测试**。
匿名卷（source 是长哈希路径）不可点。

- [ ] **Step 3: 卷 / 网络 / 镜像详情 → 容器**

三个详情页的容器行点击跳 `detail(container)`。容器对象由各自的反查结果给出。

- [ ] **Step 4: 演示数据**

`DemoOps.dockerResponse` 按现有风格补分支（**顺序有讲究**：`docker volume ls`
的 dangling 变体含 `--filter`，须先判；`docker network inspect` 要先于
`docker network ls`）：

```swift
        if command.contains("docker volume ls"), command.contains("dangling") {
            return .init(stdout: "old_cache\n")
        }
        if command.contains("docker volume inspect") { return .init(stdout: volumeInspectJSON) }
        if command.contains("docker volume ls") { return .init(stdout: volumesJSON) }
        if command.contains("docker network ls"), command.contains("dangling") {
            return .init(stdout: "none\nisolated\n")
        }
        if command.contains("docker network inspect") { return .init(stdout: networkInspectJSON) }
        if command.contains("docker network ls") { return .init(stdout: networksJSON) }
        if command.contains("docker system df") { return .init(stdout: diskUsageJSON) }
        if command.contains("docker history") { return .init(stdout: historyJSON) }
        if command.contains("docker image inspect") { return .init(stdout: imageInspectJSON) }
```

各常量的内容照 Task 1–3 测试里的夹具写，但要**扩充到能撑起截图**：至少 4 个卷
（含 1 个未使用）、4 张网络（含 bridge / host / none 与 1 张自建）、
镜像详情要有多层历史。

> **匹配顺序是这段代码唯一的坑**，`DemoOps` 现有注释也专门提过。规则：
> **更具体的判断必须排在更宽泛的之前**。
>
> - `docker volume ls --filter dangling` 与 `docker volume ls` 都含
>   `"docker volume ls"`，带 filter 的必须在前，否则 dangling 查询会拿到整份列表，
>   于是「所有卷都未使用」。网络同理。
> - `docker image inspect` 与 `docker images` 互不为子串（前者 `image` 后有空格），
>   顺序上无冲突；但把新增的 inspect 判断统一放在既有 `docker images` 之前，
>   可以避免以后有人加 `docker image` 开头的宽泛分支时踩雷。
>
> 加完后**逐条自测**：在演示模式下依次进四个分段，确认卷列表不是空的、
> 且只有 `old_cache` 带「未使用」徽标——若全部带徽标，就是这里的顺序错了。

- [ ] **Step 5: 截图验收**

```bash
cd /Users/crazyball/Code/Swift/Conn
DEV=EAA9BFB6-2D92-4831-9CFE-005A20FE35C4
APP=$(ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$DEV" "$APP"; xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_CONN_DEMO=1 SIMCTL_CHILD_CONN_SMOKE_DETAIL=1 SIMCTL_CHILD_CONN_SMOKE_SEGMENT=docker xcrun simctl launch "$DEV" "$BUNDLE"
sleep 6; xcrun simctl io "$DEV" screenshot /tmp/docker-final.png
```

用 Read 工具打开截图逐项确认，把观察写进报告：

1. 四项分段都在，标题正确
2. 容器列表与改动前一致（Task 5 的重构没有回归）
3. 搜索框在四个列表上都存在，高度一致（38pt，`ConnSearchField`）

> **卷 / 网络 / 镜像详情页无法用 `simctl` 点进去**——没有点击能力。这三个页面
> 的验收只能靠预览或真机。实现时给三个详情页各写一个 `#Preview`，用 Task 1–3
> 的夹具数据填充，在 Xcode 预览里肉眼确认后在报告里说明。**不要声称截图验证了
> 详情页。**

- [ ] **Step 6: 全量验证 + 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test 2>&1 | grep -E "✘|Test run with" | tail -2
cd /Users/crazyball/Code/Swift/Conn && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD" | head -3
cd Tooling && swiftlint lint --quiet | wc -l
git add -A && git commit -m "feat: Docker 详情页交叉跳转 + 演示数据 + 截图验收

容器详情的挂载与网络行可点跳到对应的卷 / 网络详情，反之亦然。
为此给 ContainerDetail 补 mountSources（inspect 的 Mount.Name 优先、
回退 Source），匿名卷不可点。

DemoOps 补卷 / 网络 / system df / history / image inspect 的演示数据——
没有它们，截图验收与无服务器演示模式都做不了。"
```

---

## 附：任务顺序与验证门

| 任务 | 结束时的验证门 |
|---|---|
| 1 | `swift test --filter DockerVolumeNetwork`（12 条）+ 3 次变异 |
| 2 | `swift test --filter "DockerImageDetail\|ImageUsage"`（12 条）+ 4 次变异 |
| 3 | `swift test --filter DockerDiskUsage`（7 条）+ 2 次变异 |
| 4 | `swift test --filter DockerServiceResource`（7 条）+ 全量包测试 |
| 5 | `xcodebuild build` + 全量测试 + 截图对比确认重构无回归 |
| 6 | `xcodebuild build` + lint + 四分段截图 |
| 7 | `xcodebuild build` + lint |
| 8 | 全量测试 + `xcodebuild build` + lint + 截图逐项确认 |

Task 1–4 是纯域层，互不依赖，但 2 与 3 用到 1 建立的 `decodeFirst` / `keyValueList`
辅助，**按序做**。Task 5 是纯重构，必须在 6 之前——否则 6 要往一个已经过大的
类型里塞东西。Task 8 依赖 6、7 全部落地。
