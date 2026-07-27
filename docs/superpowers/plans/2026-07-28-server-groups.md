# 服务器分组 + 列表排序修正 + 删除语义统一 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 服务器列表去掉按健康状态的排序，加上与命令分组同构的多分组筛选；同时把全库删除语义统一为真 DELETE、清掉三张死表、补上错误提示 UI。

**Architecture:** 数据层把迁移链折叠回 `SchemaV1`（删除 `SchemaV2`/`SchemaV3`），主机与命令各有一张 uuid 主键的分组表和一张带 `ON DELETE CASCADE` 外键的成员表；领域模型上 `Host.groupIDs` / `Snippet.groupIDs` 取代旧的单分组字段；UI 层抽出 `GroupFilterBar` 与 `ConnToast` 两个 ConnUI 组件供服务器页与命令页共用，分组增删改逻辑抽成 app 层的 `GroupListEditor`。

**Tech Stack:** Swift 5.10 / iOS 17 / SwiftUI + Observation / GRDB 7 / Swift Testing（`@Test` `#expect`）/ SwiftLint。

设计依据：`docs/superpowers/specs/2026-07-27-server-groups-design.md`。
表结构现状与改动后形态：`docs/数据库表设计.md`。

## Global Constraints

- **平台基线 iOS 17**，SPM 包 `platforms: [.iOS(.v17), .macOS("15.0")]`，不得提高。
- **项目未发布，不做任何向后兼容**：旧字段、旧列、旧迁移直接删除，不留 shim。DEBUG 已开 `eraseDatabaseOnSchemaChange`，模拟器数据会被清空，这是预期行为。
- **不新增迁移版本**：所有 schema 变更直接改写 `SchemaV1.register` 的建表语句。
- **全库真 DELETE**：任何表都不得再出现 `deleted_at` 列、`WHERE deleted_at IS NULL` 过滤、或名为 `softDelete` 的方法。
- **`sync_dirty` 保留**，所有实体表继续带该列，`save` 时置 1。
- **面向用户的文案一律走 `L("…")`**，源语言 zh-Hans；app 层文案进 `Conn/Conn/Localizable.xcstrings`，ConnUI 组件文案进 `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`。5 种语言：zh-Hans / en / ja / ko / zh-Hant。
- **SwiftLint 必须 0 issue**：`cd Tooling && swiftlint lint --quiet`（必须在 `Tooling/` 下运行，否则 `.build` 排除规则不生效）。
- **包测试**：`cd Packages/ConnPackages && swift test --filter <Suite>`。
- **App 构建**：`xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build`。
- **不要启动新模拟器**。需要跑 App 时先 `xcrun simctl list devices booted`，用用户已经开着的那台。
- **蛇形列名**，实体表带 `uuid TEXT PRIMARY KEY` + `created_at` / `updated_at`（毫秒）+ `sync_dirty`。

---

### Task 1: 移除指标持久化

`metric_sample` 是纯写入表：`MonitorScheduler` 每轮采集写一行，而 `MetricRepository.latest()` / `recentSamples()` 全仓无调用方（详情页趋势图走的是 `HostOverviewViewModel` 的内存数组）。整条链删除，指标改为纯内存态。

**Files:**
- Delete: `Packages/ConnPackages/Sources/ConnKit/Models/MetricSample.swift`
- Delete: `Packages/ConnPackages/Sources/ConnKit/Repositories/MetricRepository.swift`
- Delete: `Packages/ConnPackages/Sources/ConnStore/DAO/MetricStore.swift`
- Delete: `Packages/ConnPackages/Sources/ConnStore/Records/MetricRecord.swift`
- Delete: `Packages/ConnPackages/Tests/ConnStoreTests/MetricStoreTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift:104-115`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/HostMetrics.swift:7-8,58,92,125,147`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MetricCollector.swift:75-84,117`
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MonitorScheduler.swift:27,34,39,130-134`
- Modify: `Conn/Conn/ConnApp.swift:147,175-179,191,224-225,236`
- Modify: `Conn/Conn/Hosts/HostOverviewViewModel.swift:44-49`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV1Tests.swift:16-28`

**Interfaces:**
- Consumes: 无（第一个任务）。
- Produces: `HostMetrics` 不再有 `sample` 属性；`MonitorScheduler.init(connectionManager:)` 不再接受 `store:` 参数；`AppDependencies` 不再有 `metricStore` 字段。后续任务不得引用这三者。

- [ ] **Step 1: 改表清单断言，让它先失败**

`Packages/ConnPackages/Tests/ConnStoreTests/SchemaV1Tests.swift` 的 `createsAllTables` 里，把期望数组改成去掉 `metric_sample` 的版本：

```swift
        #expect(tables == [
            "app_setting", "host", "host_group", "known_host",
            "probe_target", "run_history", "snippet",
            "snippet_folder", "snippet_folder_membership", "ssh_key"
        ])
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter SchemaV1Tests
```

Expected: FAIL — 实际表清单仍含 `metric_sample`。

- [ ] **Step 3: 从 SchemaV1 删掉建表语句**

删除 `SchemaV1.swift` 中这一整段（含上方注释）：

```swift
            // 时序表：原始采样保留 48h，启动时清理
            try db.create(table: "metric_sample") { t in
                t.column("host_uuid", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("cpu", .double).notNull()
                t.column("mem", .double).notNull()
                t.column("load1", .double).notNull()
                t.column("disk_used", .double).notNull()
                t.column("disk_total", .double).notNull()
                t.column("net_rx", .integer).notNull()
                t.column("net_tx", .integer).notNull()
                t.primaryKey(["host_uuid", "ts"])
            }
```

- [ ] **Step 4: 删掉 5 个文件**

```bash
rm Packages/ConnPackages/Sources/ConnKit/Models/MetricSample.swift \
   Packages/ConnPackages/Sources/ConnKit/Repositories/MetricRepository.swift \
   Packages/ConnPackages/Sources/ConnStore/DAO/MetricStore.swift \
   Packages/ConnPackages/Sources/ConnStore/Records/MetricRecord.swift \
   Packages/ConnPackages/Tests/ConnStoreTests/MetricStoreTests.swift
```

- [ ] **Step 5: 从 HostMetrics 摘掉 sample**

`HostMetrics.swift` 共 5 处：

1. 头部文档注释里删掉第 7–8 行的这半句（保留前半段关于 nil 的说明）：
   `` `sample` 是落库用的定型样本（缺失项以 0 记入 `metric_sample`，仅供离线快照）。 ``
2. 删除属性声明 `    public let sample: MetricSample`
3. 删除 init 参数 `        sample: MetricSample`（连同它上一行参数末尾的逗号需保留正确性——`severity: MetricSeverity` 成为最后一个参数，去掉其后的逗号）
4. 删除 `        self.sample = sample`
5. `carryingOver` 里的构造调用，把 `uptimeSeconds: uptimeSeconds, severity: severity, sample: sample` 改为 `uptimeSeconds: uptimeSeconds, severity: severity`

- [ ] **Step 6: 从 MetricCollector 摘掉 sample**

删除第 75–84 行整段：

```swift
        let sample = MetricSample(
            hostUUID: host.id,
            cpu: cpuUsage ?? 0,
            mem: parsed.memPercent ?? 0,
            load1: parsed.load1 ?? 0,
            diskUsed: parsed.diskUsedBytes ?? 0,
            diskTotal: parsed.diskTotalBytes ?? 0,
            netRx: parsed.netRxBytes ?? 0,
            netTx: parsed.netTxBytes ?? 0
        )
```

并把第 117 行 `            sample: sample` 删掉（其上一行的末尾逗号需一并去掉）。

- [ ] **Step 7: 从 MonitorScheduler 摘掉 store**

删除 `    private let store: (any MetricRepository)?`、init 参数 `        store: (any MetricRepository)? = nil,`、`        self.store = store`，以及这一整段：

```swift
            // #18：首采 CPU 尚无差分(nil)，此时 sample.cpu 是占位 0，不落库以免污染历史。
            if let store, result.cpu != nil {
                let sample = result.sample
                Task.detached(priority: .utility) { try? store.record(sample) }
            }
```

- [ ] **Step 8: 跑包测试与构建**

```bash
cd Packages/ConnPackages && swift build && swift test --filter ConnStoreTests
```

Expected: 构建成功；`SchemaV1Tests` 全部 PASS。

- [ ] **Step 9: 修 App 层调用点**

`Conn/Conn/ConnApp.swift`：

1. 删除 `AppDependencies` 的字段 `    let metricStore: any MetricRepository`
2. `live()` 中把这四行：

```swift
            // 监控栈：指标仓库 + 采集调度。启动时清理超 48h 的原始样本。
            let metricStore = MetricStore(database: database)
            let cutoff = Timestamp.now() - 48 * 3600 * 1000
            try? metricStore.pruneSamples(olderThan: cutoff)
            let monitor = MonitorScheduler(connectionManager: connectionManager, store: metricStore)
```

   替换为：

```swift
            // 监控栈：采集调度。指标为纯内存态，不落库。
            let monitor = MonitorScheduler(connectionManager: connectionManager)
```

3. `live()` 与 `demo()` 的 `AppDependencies(...)` 调用里各删掉一行 `                metricStore: metricStore,`
4. `demo()` 中把 `            let metricStore = MetricStore(database: database)` 与
   `            let monitor = MonitorScheduler(connectionManager: connectionManager, store: metricStore)`
   合并为 `            let monitor = MonitorScheduler(connectionManager: connectionManager)`

`Conn/Conn/Hosts/HostOverviewViewModel.swift` 的 init 里，把：

```swift
        monitor = MonitorScheduler(
            connectionManager: dependencies.connectionManager,
            store: dependencies.metricStore
        )
```

   改为：

```swift
        monitor = MonitorScheduler(connectionManager: dependencies.connectionManager)
```

- [ ] **Step 10: 构建 App 并跑 lint**

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: `BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 11: 提交**

```bash
git add -A
git commit -m "refactor: 移除指标持久化，metric_sample 表与整条链删除

指标改为纯内存态：MonitorScheduler 每轮写库但无任何读取方，
详情页趋势图走的是 HostOverviewViewModel 的内存数组。"
```

---

### Task 2: 移除 probe_target 与 app_setting 两张死表

两张表在 `SchemaV1` 建好后从未被任何代码读写（全仓无 DAO、无 SQL 引用），设置实际走 UserDefaults 的 `SettingsStore`。

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift:117-130`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV1Tests.swift:16-28`

**Interfaces:**
- Consumes: Task 1 的表清单断言。
- Produces: 表清单收缩为 8 张（本任务后）。

- [ ] **Step 1: 改表清单断言，让它先失败**

```swift
        #expect(tables == [
            "host", "host_group", "known_host", "run_history", "snippet",
            "snippet_folder", "snippet_folder_membership", "ssh_key"
        ])
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter SchemaV1Tests
```

Expected: FAIL — 实际清单仍含 `app_setting` 与 `probe_target`。

- [ ] **Step 3: 删掉两段建表语句**

从 `SchemaV1.swift` 删除：

```swift
            try db.create(table: "probe_target") { t in
                t.primaryKey("uuid", .text)
                t.column("kind", .text).notNull() // http | tcp | ping
                t.column("endpoint", .text).notNull()
                t.column("host_uuid", .text)
                t.column("last_status", .text)
                t.column("last_latency_ms", .integer)
                t.column("cert_expire_at", .integer)
            }

            try db.create(table: "app_setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter ConnStoreTests
```

Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor: 删除从未使用的 probe_target 与 app_setting 表"
```

---

### Task 3: 全库改真删除

去掉所有 `deleted_at` 列与墓碑语义。`softDelete(id:)` 统一改名 `delete(id:)` 并改为真 DELETE，所有 `deleted_at IS NULL` 过滤移除。`BuiltinSnippets` 原先靠墓碑计数判断「导入过了」，改为 UserDefaults 标记。

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift`（4 处 `deleted_at` 列 + `idx_host_deleted` 索引）
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/Host.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/HostGroup.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/SSHKey.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/Snippet.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/HostRepository.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/HostGroupRepository.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/SSHKeyRepository.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/SnippetRepository.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Records/HostRecord.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Records/SnippetRecord.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/HostStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/HostGroupStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/SSHKeyStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/SnippetStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/BuiltinSnippets.swift`
- Modify: `Conn/Conn/Settings/SettingsStore.swift`
- Modify: `Conn/Conn/ConnApp.swift:255-257`
- Modify: `Conn/Conn/Servers/ServersViewModel.swift:63`、`Conn/Conn/Commands/SnippetsViewModel.swift:75`、`Conn/Conn/Keys/KeyManagerViewModel.swift:50`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/HostStoreTests.swift`、`HostGroupStoreTests.swift`、`SnippetStoreTests.swift`、`SchemaV1Tests.swift`、`Packages/ConnPackages/Tests/ConnKitTests/HostTests.swift`、`SnippetTests.swift`、`Conn/ConnTests/SnippetsViewModelTests.swift`

**Interfaces:**
- Consumes: Task 2 后的 `SchemaV1`。
- Produces:
  - `Host` / `HostGroup` / `SSHKey` / `Snippet` 均无 `deletedAt` 属性、init 也无该参数。
  - 四个仓库协议方法名统一为 `func delete(id: String) throws`。
  - `SnippetRepository` 不再有 `totalCount()`。
  - `SettingsStore.builtinSnippetsImported: Bool`（可读写，写入即落 UserDefaults）。
  - `BuiltinSnippets.importIfNeeded(into:)` 不再自行判空，改由调用方决定；签名保持 `@discardableResult static func importIfNeeded(into store: any SnippetRepository) throws -> Bool` 但内部去掉 `totalCount` 守卫，恒执行导入并返回 `true`。

- [ ] **Step 1: 先写失败测试 —— 删除后表中无残留行**

在 `Packages/ConnPackages/Tests/ConnStoreTests/HostStoreTests.swift` 追加：

```swift
    @Test("删除是真 DELETE，表中不留残行")
    func deleteRemovesRow() throws {
        let database = try AppDatabase.inMemory()
        let store = HostStore(database: database)
        let host = ConnKit.Host(name: "web", address: "10.0.0.1", username: "root")
        try store.save(host)

        try store.delete(id: host.id)

        #expect(try store.allHosts().isEmpty)
        let remaining = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host") ?? -1
        }
        #expect(remaining == 0)
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter HostStoreTests
```

Expected: 编译失败 —— `HostStore` 没有 `delete(id:)` 方法。

- [ ] **Step 3: SchemaV1 去掉 deleted_at 与索引**

四张实体表（`host_group`、`ssh_key`、`host`、`snippet`）各删掉一行 `t.column("deleted_at", .integer)`，并删掉 `            try db.create(index: "idx_host_deleted", on: "host", columns: ["deleted_at"])`。

- [ ] **Step 4: 领域模型去掉 deletedAt**

`Host.swift`、`HostGroup.swift`、`SSHKey.swift`、`Snippet.swift` 四个类型各删三处：属性声明 `public var deletedAt: Int64?`、init 形参 `deletedAt: Int64? = nil`、init 体内 `self.deletedAt = deletedAt`。

`Snippet.swift` 额外：`CodingKeys` 去掉 `deletedAt`，`init(from:)` 去掉解码行，`encode(to:)` 去掉 `try container.encodeIfPresent(deletedAt, forKey: .deletedAt)`。

`Host.swift` 中 `deletedAt` 上方那条注释「墓碑时间戳。非 nil 表示已删除，30 天后物理清除。」一并删除。

- [ ] **Step 5: 记录类型去掉 deletedAt**

`HostRecord.swift`：删属性 `var deletedAt: Int64?`、CodingKey `case deletedAt = "deleted_at"`、`init(_:)` 里的 `deletedAt = host.deletedAt`、`toDomain()` 里的 `deletedAt: deletedAt`（连同上一行末尾逗号调整）。

`SnippetRecord.swift`：同样四处。

`SSHKeyStore.swift` 内嵌的 `SSHKeyRecord` 与 `HostGroupStore.swift` 内嵌的 `HostGroupRecord`：同样四处。

- [ ] **Step 6: 四个仓库协议改签名**

`HostRepository.swift` / `HostGroupRepository.swift` / `SSHKeyRepository.swift` / `SnippetRepository.swift` 中：

- `func softDelete(id: String) throws` → `func delete(id: String) throws`，文档注释「软删除（写墓碑）」改为「删除（真 DELETE，不可恢复）」。
- `SnippetRepository` 删除 `func totalCount() throws -> Int` 及其文档注释。

- [ ] **Step 7: 四个 store 改实现**

`HostStore.swift`：

```swift
    /// 全部主机，按 `sortOrder` 再按名称排序。
    public func allHosts() throws -> [ConnKit.Host] {
        try database.writer.read { db in
            try HostRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// 按 id 取一台主机。
    public func host(id: String) throws -> ConnKit.Host? {
        try database.writer.read { db in
            try HostRecord.fetchOne(db, key: id).map { $0.toDomain() }
        }
    }

    /// 删除（真 DELETE，不可恢复）。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM host WHERE uuid = ?", arguments: [id])
        }
    }
```

`HostGroupStore.swift`：

```swift
    public func allGroups() throws -> [HostGroup] {
        try database.writer.read { db in
            try HostGroupRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM host_group WHERE uuid = ?", arguments: [id])
        }
    }
```

`SSHKeyStore.swift`：

```swift
    public func allKeys() throws -> [SSHKey] {
        try database.writer.read { db in
            try SSHKeyRecord.order(sql: "created_at DESC").fetchAll(db).map { $0.toDomain() }
        }
    }

    public func key(id: String) throws -> SSHKey? {
        try database.writer.read { db in
            try SSHKeyRecord.fetchOne(db, key: id).map { $0.toDomain() }
        }
    }

    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM ssh_key WHERE uuid = ?", arguments: [id])
        }
    }
```

`SnippetStore.swift`：`allSnippets()` 去掉 `.filter(sql: "deleted_at IS NULL")`；`snippet(id:)` 去掉 `record.deletedAt == nil` 判断；`count()` 去掉 filter；删除整个 `totalCount()`；`softDelete` 改：

```swift
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM snippet WHERE uuid = ?", arguments: [id])
        }
    }
```

- [ ] **Step 8: SettingsStore 加导入标记**

`Conn/Conn/Settings/SettingsStore.swift`，在 `terminalKeybarEnabled` 之后加属性：

```swift
    /// 内置命令库是否已导入过。取代旧的「数墓碑」判定——改真删除后墓碑不存在，
    /// 用户删光默认命令后不能再被重新灌回。
    var builtinSnippetsImported: Bool {
        didSet { defaults.set(builtinSnippetsImported, forKey: Key.builtinSnippetsImported) }
    }
```

init 末尾（`terminalKeybarEnabled` 赋值之后）加：

```swift
        builtinSnippetsImported = defaults.bool(forKey: Key.builtinSnippetsImported)
```

`Key` 枚举加一行：

```swift
        static let builtinSnippetsImported = "conn.settings.builtinSnippetsImported"
```

- [ ] **Step 9: BuiltinSnippets 去掉墓碑判定**

`BuiltinSnippets.swift` 的 `importIfNeeded` 改为：

```swift
    /// 导入内置分组与命令。**是否需要导入由调用方判断**
    /// （`SettingsStore.builtinSnippetsImported`）——改真删除后墓碑不存在，
    /// 无法再靠 `totalCount` 区分「从未导入」与「用户删光了」。
    @discardableResult
    public static func importIfNeeded(into store: any SnippetRepository) throws -> Bool {
        for folder in loadFolders() {
            try store.saveFolder(folder)
        }
        for snippet in load() {
            try store.save(snippet)
        }
        return true
    }
```

- [ ] **Step 10: ConnApp 改导入入口**

`Conn/Conn/ConnApp.swift` 把：

```swift
    private static func importBuiltinSnippetsIfNeeded(_ store: SnippetStore) throws {
        try BuiltinSnippets.importIfNeeded(into: store)
    }
```

改为：

```swift
    /// 首启导入内置命令库。用 UserDefaults 标记而非数据行数——改真删除后
    /// 墓碑不存在，数行数会让「用户删光默认命令」被误判为「从未导入」。
    private static func importBuiltinSnippetsIfNeeded(_ store: SnippetStore) throws {
        let defaults = UserDefaults.standard
        let key = "conn.settings.builtinSnippetsImported"
        guard !defaults.bool(forKey: key) else { return }
        try BuiltinSnippets.importIfNeeded(into: store)
        defaults.set(true, forKey: key)
    }
```

- [ ] **Step 11: 改三处 ViewModel 调用点**

- `Conn/Conn/Servers/ServersViewModel.swift`：`try? hostStore.softDelete(id: host.id)` → `try? hostStore.delete(id: host.id)`
- `Conn/Conn/Commands/SnippetsViewModel.swift`：`try? store.softDelete(id: snippet.id)` → `try? store.delete(id: snippet.id)`
- `Conn/Conn/Keys/KeyManagerViewModel.swift`：`try? keyStore.softDelete(id: key.id)` → `try? keyStore.delete(id: key.id)`

- [ ] **Step 12: 更新受影响的既有测试**

全仓搜 `softDelete`、`deletedAt`、`totalCount` 并逐个改到新 API：

```bash
grep -rn "softDelete\|deletedAt\|totalCount" Packages/ConnPackages/Tests Conn/ConnTests
```

`Conn/ConnTests/SnippetsViewModelTests.swift` 的 `StubSnippetRepository` 需同步：`softDelete` 改 `delete`，删掉 `totalCount()`。

- [ ] **Step 12b: 补内置命令导入标记的测试**

在 `Conn/ConnTests/SettingsStoreTests.swift` 追加（若文件不存在则新建，import 与既有测试一致）：

```swift
    @Test("内置命令导入标记可持久化")
    func persistsBuiltinImportFlag() {
        let suite = "conn.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SettingsStore(defaults: defaults).builtinSnippetsImported == false)
        SettingsStore(defaults: defaults).builtinSnippetsImported = true
        #expect(SettingsStore(defaults: defaults).builtinSnippetsImported)
    }
```

- [ ] **Step 13: 跑全部包测试**

```bash
cd Packages/ConnPackages && swift test
```

Expected: 全部 PASS，包含新加的 `deleteRemovesRow`。

- [ ] **Step 14: 构建 App 并 lint**

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: `BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 15: 提交**

```bash
git add -A
git commit -m "refactor: 全库删除语义统一为真 DELETE

去掉 4 张表的 deleted_at 列与所有墓碑过滤，softDelete 改名 delete。
内置命令导入判定从「数墓碑」改为 SettingsStore 标记。
代价：v1.1 iCloud 同步无法传播删除，详见设计文档。"
```

---

### Task 4: 命令分组 uuid 化

`snippet_folder` 以 `name` 为主键、无 uuid 无时间戳，是全库唯一不守约定的实体表。重建为 `snippet_group`，与 `host_group` 完全同构；成员表改按 uuid 关联并加 `ON DELETE CASCADE`。迁移链同时折叠：删除 `SchemaV2` / `SchemaV3`。

本任务跨包与 App 两层，一次做完才能编译通过。

**Files:**
- Delete: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV2.swift`
- Delete: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV3.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/SnippetGroup.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Repositories/SnippetGroupRepository.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/DAO/SnippetGroupStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift:38-42`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/Snippet.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/SnippetRepository.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Records/SnippetRecord.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/SnippetStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/BuiltinSnippets.swift`
- Modify: `Packages/ConnPackages/Sources/ConnRunner/Resources/builtin-snippets.json`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify: `Conn/Conn/Commands/SnippetsViewModel.swift`
- Modify: `Conn/Conn/Commands/SnippetsView.swift`
- Modify: `Conn/Conn/Commands/SnippetFormView.swift`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/SnippetStoreTests.swift`、`SchemaV1Tests.swift`、`Packages/ConnPackages/Tests/ConnKitTests/SnippetTests.swift`、`Conn/ConnTests/SnippetsViewModelTests.swift`

**Interfaces:**
- Consumes: Task 3 的无墓碑模型与 `delete(id:)` 签名。
- Produces:
  - `SnippetGroup`：`id` / `name` / `sortOrder` / `createdAt` / `updatedAt` / `syncDirty`，init 签名与 `HostGroup` 一致。
  - `SnippetGroupRepository`：`allGroups() throws -> [SnippetGroup]` / `save(_ group: SnippetGroup) throws` / `delete(id: String) throws`。
  - `SnippetGroupStore(database:)` 实现之。
  - `Snippet.groupIDs: [String]` 取代 `folders`；`Snippet.folder` 与自定义 `Codable` 全部删除。
  - `SnippetRepository` 不再有 `allFolders()` / `saveFolder(_:)` / `deleteFolder(_:)`。
  - `BuiltinSnippets.importIfNeeded(into:groups:)` 新签名。
  - `AppDependencies.snippetGroupRepository: any SnippetGroupRepository`。

- [ ] **Step 1: 先写失败测试 —— 分组按 uuid 关联且级联清理**

新建 `Packages/ConnPackages/Tests/ConnStoreTests/SnippetGroupStoreTests.swift`：

```swift
import ConnKit
import Foundation
import Testing
@testable import ConnStore

@Suite("SnippetGroupStore — 命令分组")
struct SnippetGroupStoreTests {
    private func makeStores() throws -> (SnippetStore, SnippetGroupStore) {
        let database = try AppDatabase.inMemory()
        return (SnippetStore(database: database), SnippetGroupStore(database: database))
    }

    @Test("重命名分组不影响成员关系")
    func renameKeepsMembership() throws {
        let (snippets, groups) = try makeStores()
        var group = SnippetGroup(name: "旧名")
        try groups.save(group)
        let snippet = Snippet(title: "ls", command: "ls", groupIDs: [group.id])
        try snippets.save(snippet)

        group.name = "新名"
        try groups.save(group)

        #expect(try groups.allGroups().map(\.name) == ["新名"])
        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [group.id])
    }

    @Test("删除分组级联清掉成员行，命令本身仍在")
    func deleteCascadesMembership() throws {
        let (snippets, groups) = try makeStores()
        let group = SnippetGroup(name: "Docker")
        try groups.save(group)
        let snippet = Snippet(title: "ps", command: "docker ps", groupIDs: [group.id])
        try snippets.save(snippet)

        try groups.delete(id: group.id)

        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [])
        #expect(try snippets.count() == 1)
    }

    @Test("保存时携带不存在的分组 id 会被静默丢弃")
    func unknownGroupIDIsDropped() throws {
        let (snippets, groups) = try makeStores()
        let group = SnippetGroup(name: "系统")
        try groups.save(group)
        let snippet = Snippet(title: "df", command: "df -h", groupIDs: [group.id, "does-not-exist"])

        try snippets.save(snippet)

        #expect(try snippets.snippet(id: snippet.id)?.groupIDs == [group.id])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter SnippetGroupStoreTests
```

Expected: 编译失败 —— `SnippetGroup` / `SnippetGroupStore` 不存在。

- [ ] **Step 3: 新建 SnippetGroup 模型**

`Packages/ConnPackages/Sources/ConnKit/Models/SnippetGroup.swift`：

```swift
import Foundation

/// 命令分组。与 `HostGroup` 同构：uuid 主键、可重命名而不影响成员关系。
public struct SnippetGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
    }
}
```

- [ ] **Step 4: 新建 SnippetGroupRepository 协议**

`Packages/ConnPackages/Sources/ConnKit/Repositories/SnippetGroupRepository.swift`：

```swift
import Foundation

/// 命令分组仓库协议。签名与 `HostGroupRepository` 保持一致。
public protocol SnippetGroupRepository: Sendable {
    /// 全部分组，按排序权重再按名称。
    func allGroups() throws -> [SnippetGroup]
    /// 新建或重命名（同 id 覆盖）。
    func save(_ group: SnippetGroup) throws
    /// 删除（真 DELETE）。成员行由外键级联清理。
    func delete(id: String) throws
}
```

- [ ] **Step 5: 改写 SchemaV1 的命令分组表**

把 `snippet` 表的 `t.column("folder", .text)` 一行删掉，并在 `snippet` 建表之后追加：

```swift
            try db.create(table: "snippet_group") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "snippet_group_membership") { t in
                t.column("snippet_uuid", .text)
                    .notNull()
                    .references("snippet", column: "uuid", onDelete: .cascade)
                t.column("group_uuid", .text)
                    .notNull()
                    .references("snippet_group", column: "uuid", onDelete: .cascade)
                t.primaryKey(["snippet_uuid", "group_uuid"])
            }
            try db.create(
                index: "idx_snippet_group_membership_group",
                on: "snippet_group_membership",
                columns: ["group_uuid"]
            )
```

- [ ] **Step 6: 删掉 SchemaV2 / SchemaV3 并摘掉注册**

```bash
rm Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV2.swift \
   Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV3.swift
```

`AppDatabase.swift` 的 `migrator` 里删掉这两行：

```swift
        SchemaV2.register(in: &migrator)
        SchemaV3.register(in: &migrator)
```

- [ ] **Step 7: 新建 SnippetGroupStore**

`Packages/ConnPackages/Sources/ConnStore/DAO/SnippetGroupStore.swift`：

```swift
import ConnKit
import Foundation
import GRDB

/// `snippet_group` 表的读写入口。
public struct SnippetGroupStore: SnippetGroupRepository {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allGroups() throws -> [SnippetGroup] {
        try database.writer.read { db in
            try SnippetGroupRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func save(_ group: SnippetGroup) throws {
        var updated = group
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try SnippetGroupRecord(updated).save($0) }
    }

    /// 成员行由 `snippet_group_membership` 的外键级联清理，此处无需手动删。
    public func delete(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM snippet_group WHERE uuid = ?", arguments: [id])
        }
    }
}

/// `snippet_group` 表的 GRDB 记录。
struct SnippetGroupRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "snippet_group"

    var uuid: String
    var name: String
    var sortOrder: Int
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
    }

    init(_ group: SnippetGroup) {
        uuid = group.id
        name = group.name
        sortOrder = group.sortOrder
        createdAt = group.createdAt
        updatedAt = group.updatedAt
        syncDirty = group.syncDirty
    }

    func toDomain() -> SnippetGroup {
        SnippetGroup(
            id: uuid,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
}
```

- [ ] **Step 8: Snippet 模型改 groupIDs**

`Snippet.swift`：把 `folders` 与 `folder` 计算属性替换为一个存储属性，并删掉整套自定义 `Codable`（`CodingKeys`、`init(from:)`、`encode(to:)`）与 `normalizedFolders`：

```swift
    /// 命令所属分组的 id。允许为空，也允许同时属于多个分组。
    public var groupIDs: [String]
```

init 的 `folder` / `folders` 两个参数合并为 `groupIDs: [String] = []`，init 体内改为 `self.groupIDs = groupIDs`。

- [ ] **Step 9: SnippetRecord 去掉 folder**

删属性 `var folder: String?`、CodingKeys 里的 `folder`、`init(_:)` 的 `folder = snippet.folder`；`toDomain` 改签名：

```swift
    func toDomain(groupIDs: [String]) -> Snippet {
        Snippet(
            id: uuid,
            title: title,
            command: command,
            groupIDs: groupIDs,
            pinned: pinned,
            danger: danger,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty
        )
    }
```

- [ ] **Step 10: SnippetStore 改成员读写**

`SnippetRepository.swift` 删掉 `allFolders()` / `saveFolder(_:)` / `deleteFolder(_:)` 三个方法声明。`SnippetStore.swift` 删掉对应实现与 `normalizedFolders`，并把 `save` 与私有查询改成：

```swift
    /// 插入或整体覆盖。先写实体记录再写成员行——外键要求两端实体已存在。
    /// 库中不存在的 group id 会被静默丢弃（分组被删是良性竞态），
    /// 否则外键违例会打掉整个保存事务。
    public func save(_ snippet: Snippet) throws {
        var updated = snippet
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { db in
            try SnippetRecord(updated).save(db)
            try db.execute(
                sql: "DELETE FROM snippet_group_membership WHERE snippet_uuid = ?",
                arguments: [updated.id]
            )
            var seen = Set<String>()
            for groupID in updated.groupIDs where seen.insert(groupID).inserted {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM snippet_group WHERE uuid = ?)",
                    arguments: [groupID]
                ) ?? false
                guard exists else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO snippet_group_membership (snippet_uuid, group_uuid)
                    VALUES (?, ?)
                    """,
                    arguments: [updated.id, groupID]
                )
            }
        }
    }

    private func groupIDs(for snippetID: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT membership.group_uuid
            FROM snippet_group_membership AS membership
            JOIN snippet_group AS grp ON grp.uuid = membership.group_uuid
            WHERE membership.snippet_uuid = ?
            ORDER BY grp.sort_order ASC, grp.name COLLATE NOCASE
            """,
            arguments: [snippetID]
        )
    }
```

`allSnippets()` 与 `snippet(id:)` 里的 `record.toDomain(folders: folders(for:...))` 改为 `record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))`。

- [ ] **Step 11: 跑包测试**

```bash
cd Packages/ConnPackages && swift test --filter ConnStoreTests
```

Expected: `SnippetGroupStoreTests` 三条全部 PASS。若 `deleteCascadesMembership` 失败，检查 `AppDatabase.baseConfiguration` 的 `foreignKeysEnabled` 是否仍为 `true`。

- [ ] **Step 12: 内置命令库 JSON 改键名**

`Packages/ConnPackages/Sources/ConnRunner/Resources/builtin-snippets.json`：顶层的 `"folders"` 键改为 `"groups"`，每条命令对象里的 `"folders"` 键同样改为 `"groups"`。

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path("Packages/ConnPackages/Sources/ConnRunner/Resources/builtin-snippets.json")
d = json.loads(p.read_text())
d["groups"] = d.pop("folders")
for c in d["commands"]:
    c["groups"] = c.pop("folders")
p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
```

- [ ] **Step 13: BuiltinSnippets 改按 id 关联**

```swift
import ConnKit
import Foundation

/// 内置模板库（方案 §4.6：JSON 资源，首启可跳过导入）。
public enum BuiltinSnippets {
    private struct LibraryDTO: Decodable {
        let groups: [String]
        let commands: [CommandDTO]
    }

    private struct CommandDTO: Decodable {
        let title: String
        let command: String
        let groups: [String]
        let pinned: Bool?
        let danger: Bool?
    }

    private static func decodeLibrary() -> LibraryDTO? {
        guard let url = Bundle.module.url(forResource: "builtin-snippets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(LibraryDTO.self, from: data)
        else { return nil }
        return library
    }

    /// 从同一个内置 JSON 载入有序分组名（按当前语言本地化一次，事后切语言不重译）。
    public static func loadGroupNames() -> [String] {
        (decodeLibrary()?.groups ?? []).map { L($0) }
    }

    /// 导入内置分组与命令。**是否需要导入由调用方判断**
    /// （`SettingsStore.builtinSnippetsImported`）。
    @discardableResult
    public static func importIfNeeded(
        into store: any SnippetRepository,
        groups groupStore: any SnippetGroupRepository
    ) throws -> Bool {
        var idByName: [String: String] = [:]
        for (index, name) in loadGroupNames().enumerated() {
            let group = SnippetGroup(name: name, sortOrder: index)
            try groupStore.save(group)
            idByName[name] = group.id
        }
        for (index, dto) in (decodeLibrary()?.commands ?? []).enumerated() {
            let names = dto.groups.map { L($0) }
            try store.save(Snippet(
                title: L(dto.title),
                command: dto.command,
                groupIDs: names.compactMap { idByName[$0] },
                pinned: dto.pinned ?? false,
                danger: dto.danger ?? false,
                sortOrder: index
            ))
        }
        return true
    }
}
```

- [ ] **Step 14: ConnApp 装配 SnippetGroupStore**

`AppDependencies` 加字段（放在 `snippetRepository` 之后）：

```swift
    /// 命令分组仓库。与 `hostGroupRepository` 同构。
    let snippetGroupRepository: any SnippetGroupRepository
```

`live()` 与 `demo()` 各自在 `let snippetStore = SnippetStore(database: database)` 之后加：

```swift
            let snippetGroupStore = SnippetGroupStore(database: database)
```

把 `try importBuiltinSnippetsIfNeeded(snippetStore)` 改为 `try importBuiltinSnippetsIfNeeded(snippetStore, snippetGroupStore)`，两处 `AppDependencies(...)` 各加一行 `                snippetGroupRepository: snippetGroupStore,`。

导入辅助方法改签名：

```swift
    private static func importBuiltinSnippetsIfNeeded(
        _ store: SnippetStore,
        _ groups: SnippetGroupStore
    ) throws {
        let defaults = UserDefaults.standard
        let key = "conn.settings.builtinSnippetsImported"
        guard !defaults.bool(forKey: key) else { return }
        try BuiltinSnippets.importIfNeeded(into: store, groups: groups)
        defaults.set(true, forKey: key)
    }
```

- [ ] **Step 15: SnippetsViewModel 改按 id**

```swift
enum SnippetListFilter: Hashable {
    case favorites
    case all
    case group(String) // 载荷是 SnippetGroup.id
}
```

`SnippetsViewModel`：`private(set) var groups: [SnippetGroup] = []`；构造函数增加 `groupStore: any SnippetGroupRepository` 并保存；`load()` 改 `groups = try groupStore.allGroups()`；

```swift
    func snippets(for filter: SnippetListFilter) -> [Snippet] {
        switch filter {
        case .favorites:
            searchResults.filter(\.pinned)
        case .all:
            searchResults
        case let .group(id):
            searchResults.filter { $0.groupIDs.contains(id) }
        }
    }

    func commandCount(in groupID: String) -> Int {
        snippets.count { $0.groupIDs.contains(groupID) }
    }

    var filteredGroups: [SnippetGroup] {
        guard !searchText.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func addGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try groupStore.save(SnippetGroup(
                name: trimmed,
                sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1
            ))
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func deleteGroup(id: String) {
        do {
            try groupStore.delete(id: id)
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }
```

> Task 7 会把 `addGroup` / `deleteGroup` 收敛进 `GroupListEditor` 并补上重名校验与 `renameGroup`，此处先保证编译与行为不退化。

- [ ] **Step 16: SnippetsView / SnippetFormView 改按 id**

`SnippetsView.swift`：
- `GroupDeleteRequest` 的 `name: String` 改为持有 `SnippetGroup`：`let group: SnippetGroup`，`var id: String { group.id }`
- `commandFilters` 里 `ForEach(viewModel.groups, id: \.self)` 改为 `ForEach(viewModel.groups) { group in filterChip(title: group.name, filter: .group(group.id)) }`
- `groupList` 的 `ForEach(viewModel.filteredGroups, id: \.self)` 改为 `ForEach(viewModel.filteredGroups) { group in groupRow(group) ... }`
- `groupRow(_ group: String)` 改为 `groupRow(_ group: SnippetGroup)`，内部 `Text(group)` → `Text(group.name)`，`viewModel.commandCount(in: group)` → `viewModel.commandCount(in: group.id)`，`selectedFilter = .group(group)` → `.group(group.id)`
- 删除确认块里 `viewModel.deleteGroup(request.name)` → `viewModel.deleteGroup(id: request.group.id)`，`if selectedFilter == .group(request.name)` → `.group(request.group.id)`
- `.sheet(item: $formRequest)` 传参 `groups: viewModel.groups`

`SnippetFormView.swift`：`groups` 参数类型改 `[SnippetGroup]`，`selectedGroups` 改为 `Set<String>`（存 id），初值 `Set(snippet?.groupIDs ?? [])`；`availableGroups` 改为返回 `[SnippetGroup]`（把 `snippet?.groupIDs` 中不在 `groups` 里的 id 忽略即可，不再需要补齐）；行内 `Text(group)` → `Text(group.name)`，`selectedGroups.contains(group)` → `selectedGroups.contains(group.id)`；`save()` 里 `updated.folders = ...` → `updated.groupIDs = groups.map(\.id).filter(selectedGroups.contains)`，新建分支同理传 `groupIDs:`。

- [ ] **Step 17: 更新受影响测试**

- `SchemaV1Tests.createsAllTables` 期望清单改为：
  `["host", "host_group", "known_host", "run_history", "snippet", "snippet_group", "snippet_group_membership", "ssh_key"]`
- 删除 `SchemaV1Tests.migratesLegacySnippetFolders`（它专测 V3 搬迁路径，该路径已不存在）
- `SnippetTests.swift`、`SnippetStoreTests.swift` 中所有 `folders:` / `folder:` 改 `groupIDs:`
- `Conn/ConnTests/SnippetsViewModelTests.swift`：`StubSnippetRepository` 删掉 `allFolders` / `saveFolder` / `deleteFolder`，新增 `StubSnippetGroupRepository`：

```swift
private final class StubSnippetGroupRepository: SnippetGroupRepository, @unchecked Sendable {
    var groups: [SnippetGroup]

    init(groups: [SnippetGroup] = []) { self.groups = groups }

    func allGroups() throws -> [SnippetGroup] { groups.sorted { $0.sortOrder < $1.sortOrder } }

    func save(_ group: SnippetGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }

    func delete(id: String) throws { groups.removeAll { $0.id == id } }
}
```

  并把 `SnippetsViewModel(store:)` 的构造改为 `SnippetsViewModel(store:groupStore:)`。

- [ ] **Step 18: 全量验证**

```bash
cd Packages/ConnPackages && swift test
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: 包测试全绿；`BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 19: 提交**

```bash
git add -A
git commit -m "refactor: 命令分组改为 uuid 主键 + 级联成员表，迁移链折叠回 SchemaV1

snippet_folder/snippet_folder_membership 重建为 snippet_group/
snippet_group_membership，与 host_group 同构；删除 SchemaV2/V3。"
```

---

### Task 5: 主机分组数据层

给主机加上与命令完全对称的多分组能力：`host_group_membership` 成员表 + `Host.groupIDs`，去掉从未接入 UI 的单分组外键 `host.group_uuid`。

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/Host.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/HostDraft.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Records/HostRecord.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/HostStore.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift:47-49`
- Modify: `Conn/Conn/ConnApp.swift`（`groupRepository` 改名 `hostGroupRepository`）
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/HostGroupStoreTests.swift`、`HostStoreTests.swift`、`SchemaV1Tests.swift`、`Packages/ConnPackages/Tests/ConnKitTests/HostTests.swift`、`HostDraftTests.swift`

**Interfaces:**
- Consumes: Task 3 的无墓碑模型、Task 4 的 `snippet_group_membership` 写法（照抄结构）。
- Produces:
  - `Host.groupIDs: [String]`，init 参数 `groupIDs: [String] = []`（`groupUUID` 已删除）。
  - `HostDraft.groupIDs: [String]`，init 参数同名。
  - `AppDependencies.hostGroupRepository`（原 `groupRepository` 改名）。

- [ ] **Step 1: 先写失败测试**

在 `Packages/ConnPackages/Tests/ConnStoreTests/HostGroupStoreTests.swift` 追加：

```swift
    @Test("主机可属于多个分组，重命名不影响成员关系")
    func multiGroupMembership() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        var prod = HostGroup(name: "生产", sortOrder: 0)
        let web = HostGroup(name: "Web", sortOrder: 1)
        try store.save(prod)
        try store.save(web)
        let host = ConnKit.Host(name: "web-01", address: "10.0.0.1", username: "root",
                                groupIDs: [prod.id, web.id])
        try hosts.save(host)

        prod.name = "PROD"
        try store.save(prod)

        #expect(try hosts.host(id: host.id)?.groupIDs == [prod.id, web.id])
    }

    @Test("删除分组级联清成员行，主机仍在")
    func deleteCascadesMembership() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        let group = HostGroup(name: "临时")
        try store.save(group)
        let host = ConnKit.Host(name: "a", address: "1", username: "r", groupIDs: [group.id])
        try hosts.save(host)

        try store.delete(id: group.id)

        #expect(try hosts.host(id: host.id)?.groupIDs == [])
        #expect(try hosts.allHosts().count == 1)
    }

    @Test("保存时携带不存在的分组 id 会被静默丢弃")
    func unknownGroupIDIsDropped() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let store = HostGroupStore(database: database)
        let group = HostGroup(name: "生产")
        try store.save(group)
        let host = ConnKit.Host(name: "a", address: "1", username: "r",
                                groupIDs: [group.id, "does-not-exist"])

        try hosts.save(host)

        #expect(try hosts.host(id: host.id)?.groupIDs == [group.id])
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter HostGroupStoreTests
```

Expected: 编译失败 —— `Host` 没有 `groupIDs` 参数。

- [ ] **Step 3: SchemaV1 改主机分组结构**

`host` 表删掉 `                t.column("group_uuid", .text).references("host_group", column: "uuid", onDelete: .setNull)`，删掉 `            try db.create(index: "idx_host_group", on: "host", columns: ["group_uuid"])`，并在 `host` 建表与索引之后追加：

```swift
            try db.create(table: "host_group_membership") { t in
                t.column("host_uuid", .text)
                    .notNull()
                    .references("host", column: "uuid", onDelete: .cascade)
                t.column("group_uuid", .text)
                    .notNull()
                    .references("host_group", column: "uuid", onDelete: .cascade)
                t.primaryKey(["host_uuid", "group_uuid"])
            }
            try db.create(
                index: "idx_host_group_membership_group",
                on: "host_group_membership",
                columns: ["group_uuid"]
            )
```

- [ ] **Step 4: Host / HostDraft 改 groupIDs**

`Host.swift`：`public var groupUUID: String?` → `public var groupIDs: [String]`；init 参数 `groupUUID: String? = nil` → `groupIDs: [String] = []`；init 体 `self.groupUUID = groupUUID` → `self.groupIDs = groupIDs`。

`HostDraft.swift`：同样三处；`init(from host:)` 里 `groupUUID = host.groupUUID` → `groupIDs = host.groupIDs`；`toHost` 里 `groupUUID: groupUUID` → `groupIDs: groupIDs`。

- [ ] **Step 5: HostRecord 去掉 groupUUID**

删属性 `var groupUUID: String?`、CodingKey `case groupUUID = "group_uuid"`、`init(_:)` 的 `groupUUID = host.groupUUID`；`toDomain()` 改签名：

```swift
    func toDomain(groupIDs: [String] = []) -> DomainHost {
```

并把 `groupUUID: groupUUID,` 改为 `groupIDs: groupIDs,`。

- [ ] **Step 6: HostStore 读写成员行**

```swift
    /// 插入或整体覆盖一台主机。
    ///
    /// 会自动刷新 `updatedAt` 并置 `syncDirty`。先写实体记录再写成员行——
    /// 外键要求两端实体已存在；库中不存在的 group id 静默丢弃，
    /// 否则外键违例会打掉整个保存事务。
    public func save(_ host: ConnKit.Host) throws {
        var updated = host
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { db in
            try HostRecord(updated).save(db)
            try db.execute(
                sql: "DELETE FROM host_group_membership WHERE host_uuid = ?",
                arguments: [updated.id]
            )
            var seen = Set<String>()
            for groupID in updated.groupIDs where seen.insert(groupID).inserted {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM host_group WHERE uuid = ?)",
                    arguments: [groupID]
                ) ?? false
                guard exists else { continue }
                try db.execute(
                    sql: "INSERT INTO host_group_membership (host_uuid, group_uuid) VALUES (?, ?)",
                    arguments: [updated.id, groupID]
                )
            }
        }
    }

    public func allHosts() throws -> [ConnKit.Host] {
        try database.writer.read { db in
            try HostRecord
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { try $0.toDomain(groupIDs: groupIDs(for: $0.uuid, in: db)) }
        }
    }

    public func host(id: String) throws -> ConnKit.Host? {
        try database.writer.read { db in
            guard let record = try HostRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain(groupIDs: groupIDs(for: record.uuid, in: db))
        }
    }

    private func groupIDs(for hostID: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT membership.group_uuid
            FROM host_group_membership AS membership
            JOIN host_group AS grp ON grp.uuid = membership.group_uuid
            WHERE membership.host_uuid = ?
            ORDER BY grp.sort_order ASC, grp.name COLLATE NOCASE
            """,
            arguments: [hostID]
        )
    }
```

> `allHosts` 的 `.map` 闭包会抛错，需写成 `try ... .map { ... }`，如上。

- [ ] **Step 7: 更新外键注释**

`AppDatabase.swift` 的 `baseConfiguration` 注释改为：

```swift
        // 外键约束必须开启：host.key_uuid 与两张成员表的 ON DELETE CASCADE 依赖它。
        // 改真删除后这些级联才第一次真正触发（软删除时代从不触发）。
```

- [ ] **Step 8: AppDependencies 改名**

`Conn/Conn/ConnApp.swift`：`let groupRepository: any HostGroupRepository` → `let hostGroupRepository: any HostGroupRepository`；`live()` / `demo()` 的两处 `groupRepository: groupStore,` → `hostGroupRepository: groupStore,`。

- [ ] **Step 9: 更新表清单断言与既有测试**

`SchemaV1Tests.createsAllTables` 期望清单改为最终 9 张：

```swift
        #expect(tables == [
            "host", "host_group", "host_group_membership", "known_host",
            "run_history", "snippet", "snippet_group",
            "snippet_group_membership", "ssh_key"
        ])
```

`HostTests.swift`、`HostDraftTests.swift`、`HostStoreTests.swift` 中所有 `groupUUID` 改 `groupIDs`（值类型从 `String?` 变 `[String]`）。

- [ ] **Step 10: 全量验证**

```bash
cd Packages/ConnPackages && swift test
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: 包测试全绿；`BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 11: 提交**

```bash
git add -A
git commit -m "feat: 主机支持多分组，host_group_membership 级联成员表

删除从未接入 UI 的 host.group_uuid 单分组外键，
Host.groupIDs 与 Snippet.groupIDs 现在完全对称。"
```

---

### Task 6: GroupListEditor —— 分组增删改的共用规则

两个页面的分组校验逻辑逐字相同（空名、重名、排序权重）。抽成 app 层的共用类型。

> **与设计文档的偏离**：spec 写的是「持有一个 group 仓库并对外提供 add/rename/delete」。
> 实际实现改为**只做规则、不持有仓库**——`HostGroupRepository` 与 `SnippetGroupRepository`
> 是两个元素类型不同的协议，泛型化后 `AppDependencies` 里的 `any XxxRepository`
> 存在类型无法满足泛型约束，得再套一层类型擦除，代码量与理解成本都超过它消除的重复。
> 持久化留在各自 ViewModel（各约 8 行），真正易错的校验规则完全共用。

**Files:**
- Create: `Conn/Conn/Support/GroupListEditor.swift`
- Test: `Conn/ConnTests/GroupListEditorTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `GroupListEditor.validate(name:against:) throws -> String`（返回 trim 后的名称）
  - `GroupListEditor.nextSortOrder(after:) -> Int`
  - `GroupListEditor.Failure`（`.emptyName` / `.duplicateName`），带 `message: String`

- [ ] **Step 1: 写失败测试**

`Conn/ConnTests/GroupListEditorTests.swift`：

```swift
import Foundation
import Testing
@testable import Conn

@MainActor
struct GroupListEditorTests {
    @Test("空名与纯空白被拒")
    func rejectsEmptyName() {
        #expect(throws: GroupListEditor.Failure.emptyName) {
            try GroupListEditor.validate(name: "   ", against: [])
        }
    }

    @Test("重名被拒，且不分大小写、忽略首尾空格")
    func rejectsDuplicateName() {
        #expect(throws: GroupListEditor.Failure.duplicateName) {
            try GroupListEditor.validate(name: " docker ", against: ["Docker"])
        }
    }

    @Test("重命名时排除自身则不算重名")
    func allowsRenameToSelf() throws {
        let result = try GroupListEditor.validate(name: "Docker", against: ["日志"])
        #expect(result == "Docker")
    }

    @Test("合法名称返回 trim 后的结果")
    func trimsValidName() throws {
        #expect(try GroupListEditor.validate(name: "  生产  ", against: []) == "生产")
    }

    @Test("新分组排序权重取现有最大值 +1")
    func nextSortOrderIncrements() {
        #expect(GroupListEditor.nextSortOrder(after: []) == 0)
        #expect(GroupListEditor.nextSortOrder(after: [0, 3, 1]) == 4)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" \
  -only-testing:ConnTests/GroupListEditorTests 2>&1 | tail -20
```

Expected: 编译失败 —— `GroupListEditor` 不存在。

> 若没有已启动的模拟器，先让用户启动一台；**不要自行 boot 新模拟器**。

- [ ] **Step 3: 实现 GroupListEditor**

`Conn/Conn/Support/GroupListEditor.swift`：

```swift
import Foundation

/// 分组增删改的共用规则。
///
/// 只做校验与排序权重计算，不碰仓库——持久化留在各自 ViewModel。
/// 服务器页与命令页共用同一套判定，避免两处规则漂移。
enum GroupListEditor {
    enum Failure: Error, Equatable {
        case emptyName
        case duplicateName

        var message: String {
            switch self {
            case .emptyName: L("分组名称不能为空")
            case .duplicateName: L("已存在同名分组")
            }
        }
    }

    /// 校验新建 / 重命名用的分组名。
    ///
    /// - Parameters:
    ///   - name: 用户输入的原始名称。
    ///   - existingNames: 现有分组名。**重命名时必须排除被改的那个自身**，
    ///     否则原名会把自己判成重名。
    /// - Returns: trim 后的合法名称。
    static func validate(name: String, against existingNames: [String]) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        let clash = existingNames.contains { existing in
            existing.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        guard !clash else { throw Failure.duplicateName }
        return trimmed
    }

    /// 新分组的排序权重：现有最大值 +1。
    static func nextSortOrder(after existing: [Int]) -> Int {
        (existing.max() ?? -1) + 1
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" \
  -only-testing:ConnTests/GroupListEditorTests 2>&1 | tail -20
```

Expected: 5 条全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 新增 GroupListEditor 共用分组校验规则"
```

---

### Task 7: ConnToast 组件

`errorMessage` 在全仓从未被任何 View 渲染过，所有失败对用户静默。补一个顶部浮层 toast。

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnUI/Components/ConnToast.swift`
- Test: `Packages/ConnPackages/Tests/ConnUITests/ConnToastTests.swift`

**Interfaces:**
- Consumes: `ConnSpacing` / `ConnRadius` / `Color.connSurface` / `.connCrit` / `.connInk` 令牌。
- Produces:
  - `View.connToast(message: Binding<String?>) -> some View`
  - `ConnToastTimer.autoDismissDuration: Duration`（3.5s）
  - `ConnToastTimer.waitForAutoDismiss(_:) async -> Bool`

- [ ] **Step 1: 写失败测试**

`Packages/ConnPackages/Tests/ConnUITests/ConnToastTests.swift`：

```swift
import Foundation
import Testing
@testable import ConnUI

@Suite("ConnToast — 自动消失时序")
struct ConnToastTests {
    @Test("默认自动消失时长为 3.5 秒")
    func defaultDuration() {
        #expect(ConnToastTimer.autoDismissDuration == .seconds(3.5))
    }

    @Test("等待结束返回 true，表示应清空消息")
    func waitCompletes() async {
        let shouldDismiss = await ConnToastTimer.waitForAutoDismiss(.milliseconds(10))
        #expect(shouldDismiss)
    }

    @Test("被取消时返回 false，不清空消息")
    func cancelledWaitDoesNotDismiss() async {
        let task = Task { await ConnToastTimer.waitForAutoDismiss(.seconds(10)) }
        task.cancel()
        #expect(await task.value == false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter ConnToastTests
```

Expected: 编译失败 —— `ConnToastTimer` 不存在。

- [ ] **Step 3: 实现组件**

`Packages/ConnPackages/Sources/ConnUI/Components/ConnToast.swift`：

```swift
import SwiftUI

/// Toast 的自动消失计时。抽成独立类型以便脱离 SwiftUI 单测。
public enum ConnToastTimer {
    /// 默认停留时长。
    public static let autoDismissDuration: Duration = .seconds(3.5)

    /// 等待自动消失。
    /// - Returns: 正常等到时长结束返回 `true`（应清空消息）；
    ///   被取消（例如新消息顶掉旧消息）返回 `false`。
    public static func waitForAutoDismiss(
        _ duration: Duration = autoDismissDuration
    ) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}

/// 顶部浮层提示条。
///
/// 挂在**页面内容视图**上（`NavigationStack` 内部），因此天然落在导航栏下方、
/// 不与大标题重叠。点击或上滑可提前关闭。
struct ConnToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.connCrit)
            Text(message)
                .font(.connFootnote)
                .foregroundStyle(.connInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, ConnSpacing.xs)
        .connSurface(cornerRadius: ConnRadius.control)
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < 0 { onDismiss() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct ConnToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    ConnToast(message: message) { self.message = nil }
                        .padding(.horizontal, ConnSpacing.page)
                        .padding(.top, ConnSpacing.sm)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                        // id 绑到消息内容：后到的消息顶掉前一条并重置计时器，不排队叠加。
                        .task(id: message) {
                            if await ConnToastTimer.waitForAutoDismiss() {
                                self.message = nil
                            }
                        }
                }
            }
            .animation(
                reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86),
                value: message
            )
    }
}

public extension View {
    /// 绑定一段可空提示文案：非 nil 即从导航栏下方滑入，3.5s 后自动清空。
    func connToast(message: Binding<String?>) -> some View {
        modifier(ConnToastModifier(message: message))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter ConnToastTests
```

Expected: 3 条全部 PASS。

- [ ] **Step 5: 补 ConnUI 文案到 xcstrings**

本组件无硬编码用户文案（消息由调用方传入），无需新增条目。跑一次 lint 确认格式：

```bash
cd Tooling && swiftlint lint --quiet
```

Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: 新增 ConnToast 顶部浮层提示组件"
```

---

### Task 8: GroupFilterBar 组件

服务器页与命令页各有一份几乎相同的 `filterChip`，收敛成一个组件，并把「长按重命名/删除」一并内建。

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnUI/Components/GroupFilterBar.swift`
- Test: `Packages/ConnPackages/Tests/ConnUITests/GroupFilterBarTests.swift`

**Interfaces:**
- Consumes: `ConnSpacing` / `ConnRadius` / `ConnPressStyle` / `connHitTarget()` / 颜色令牌。
- Produces:
  - `GroupFilterBar.Item`：`init(id: String, title: String)`，`Identifiable` + `Equatable`。
  - `GroupFilterBar(allTitle:leading:groups:selection:onRename:onDelete:)`，
    `selection: Binding<String?>`，`nil` 表示选中「全部」。
  - `GroupFilterBar.nextSelection(tapped:current:) -> String?`（纯函数，供单测）。

- [ ] **Step 1: 写失败测试**

`Packages/ConnPackages/Tests/ConnUITests/GroupFilterBarTests.swift`：

```swift
import Foundation
import Testing
@testable import ConnUI

@Suite("GroupFilterBar — 选择行为")
struct GroupFilterBarTests {
    @Test("点未选中的 chip 即选中它")
    func selectsTapped() {
        #expect(GroupFilterBar.nextSelection(tapped: "g1", current: nil) == "g1")
        #expect(GroupFilterBar.nextSelection(tapped: "g2", current: "g1") == "g2")
    }

    @Test("再点一次当前选中的 chip 回到「全部」")
    func retapReturnsToAll() {
        #expect(GroupFilterBar.nextSelection(tapped: "g1", current: "g1") == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter GroupFilterBarTests
```

Expected: 编译失败 —— `GroupFilterBar` 不存在。

- [ ] **Step 3: 实现组件**

`Packages/ConnPackages/Sources/ConnUI/Components/GroupFilterBar.swift`：

```swift
import SwiftUI

/// 分组筛选条：`全部` + 各分组 chip，单选，横向滚动。
///
/// 分组 chip 长按弹出重命名 / 删除；`leading` 里的前置 chip
/// （如命令页的「常用」）不是分组，不带上下文菜单。
public struct GroupFilterBar: View {
    /// 一个可点选的 chip。
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    private let allTitle: String
    private let leading: [Item]
    private let groups: [Item]
    @Binding private var selection: String?
    private let onRename: (Item) -> Void
    private let onDelete: (Item) -> Void

    /// - Parameters:
    ///   - allTitle: 「全部」chip 的标题。
    ///   - leading: 插在「全部」之前的非分组 chip，可为空。
    ///   - groups: 分组 chip。
    ///   - selection: 当前选中项 id；`nil` 表示「全部」。
    public init(
        allTitle: String,
        leading: [Item] = [],
        groups: [Item],
        selection: Binding<String?>,
        onRename: @escaping (Item) -> Void,
        onDelete: @escaping (Item) -> Void
    ) {
        self.allTitle = allTitle
        self.leading = leading
        self.groups = groups
        _selection = selection
        self.onRename = onRename
        self.onDelete = onDelete
    }

    /// 点击某个 chip 后的新选中值。再点当前项回到「全部」（nil）。
    public static func nextSelection(tapped id: String, current: String?) -> String? {
        current == id ? nil : id
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xs) {
                ForEach(leading) { item in
                    chip(title: item.title, isSelected: selection == item.id) {
                        selection = Self.nextSelection(tapped: item.id, current: selection)
                    }
                }
                chip(title: allTitle, isSelected: selection == nil) { selection = nil }
                ForEach(groups) { group in
                    chip(title: group.title, isSelected: selection == group.id) {
                        selection = Self.nextSelection(tapped: group.id, current: selection)
                    }
                    .contextMenu {
                        Button {
                            onRename(group)
                        } label: {
                            Label(L("重命名分组"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            onDelete(group)
                        } label: {
                            Label(L("删除分组"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, ConnSpacing.page)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.connFootnote)
                .foregroundStyle(isSelected ? .connAccent : .connMuted)
                .padding(.horizontal, ConnSpacing.sm)
                .padding(.vertical, 6)
                .background(isSelected ? Color.connAccentFill : Color.connSurface, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(
                        isSelected ? Color.connAccent.opacity(0.5) : Color.connLine,
                        lineWidth: 1
                    )
                }
                .connHitTarget()
        }
        .buttonStyle(ConnPressStyle())
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter GroupFilterBarTests
```

Expected: 2 条全部 PASS。

- [ ] **Step 5: 补 ConnUI 文案**

`Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings` 新增两条（zh-Hans 源 + en/ja/ko/zh-Hant）：

| key | en | ja | ko | zh-Hant |
|---|---|---|---|---|
| `重命名分组` | Rename Group | グループ名を変更 | 그룹 이름 변경 | 重新命名分組 |
| `删除分组` | Delete Group | グループを削除 | 그룹 삭제 | 刪除分組 |

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: 新增 GroupFilterBar 分组筛选条组件"
```

---

### Task 9: ServersViewModel —— 去掉状态排序，接入分组

**Files:**
- Modify: `Conn/Conn/Servers/ServersViewModel.swift`
- Test: `Conn/ConnTests/ServersViewModelTests.swift`（新建）

**Interfaces:**
- Consumes: Task 5 的 `Host.groupIDs` 与 `AppDependencies.hostGroupRepository`；Task 6 的 `GroupListEditor`。
- Produces:
  - `ServersViewModel.init(hostStore:groupStore:monitor:)`
  - `groups: [HostGroup]`、`selectedGroupID: String?`、`errorMessage: String?`
  - `addGroup(_:)` / `renameGroup(id:to:)` / `deleteGroup(id:)` / `clearError()`

- [ ] **Step 1: 写失败测试**

`Conn/ConnTests/ServersViewModelTests.swift`：

```swift
import ConnKit
import ConnMonitor
import ConnSSH
import Foundation
import Testing
@testable import Conn

private final class StubHostRepository: HostRepository, @unchecked Sendable {
    var hosts: [Host]
    init(hosts: [Host] = []) { self.hosts = hosts }
    func allHosts() throws -> [Host] { hosts }
    func host(id: String) throws -> Host? { hosts.first { $0.id == id } }
    func save(_ host: Host) throws { hosts.append(host) }
    func delete(id: String) throws { hosts.removeAll { $0.id == id } }
}

private final class StubHostGroupRepository: HostGroupRepository, @unchecked Sendable {
    var groups: [HostGroup]
    init(groups: [HostGroup] = []) { self.groups = groups }
    func allGroups() throws -> [HostGroup] { groups.sorted { $0.sortOrder < $1.sortOrder } }
    func save(_ group: HostGroup) throws {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }
    func delete(id: String) throws { groups.removeAll { $0.id == id } }
}

@MainActor
struct ServersViewModelTests {
    private func makeViewModel(
        hosts: [Host] = [],
        groups: [HostGroup] = []
    ) -> (ServersViewModel, StubHostGroupRepository) {
        let groupStore = StubHostGroupRepository(groups: groups)
        // MockSSHTransport 与 ConnectionManager 的参数都有默认值，测试里不会真的连接。
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: MockSSHTransport())
        )
        let viewModel = ServersViewModel(
            hostStore: StubHostRepository(hosts: hosts),
            groupStore: groupStore,
            monitor: monitor
        )
        viewModel.load()
        return (viewModel, groupStore)
    }

    @Test("卡片顺序照抄仓库顺序，不受健康状态影响")
    func keepsRepositoryOrder() {
        let hosts = [
            Host(name: "c-host", address: "3", username: "r"),
            Host(name: "a-host", address: "1", username: "r"),
            Host(name: "b-host", address: "2", username: "r")
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts)

        #expect(viewModel.cards.map(\.name) == ["c-host", "a-host", "b-host"])
    }

    @Test("按分组筛选")
    func filtersByGroup() {
        let prod = HostGroup(name: "生产")
        let hosts = [
            Host(name: "web", address: "1", username: "r", groupIDs: [prod.id]),
            Host(name: "nas", address: "2", username: "r")
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.selectedGroupID = prod.id

        #expect(viewModel.cards.map(\.name) == ["web"])
    }

    @Test("搜索与分组取交集")
    func combinesSearchAndGroup() {
        let prod = HostGroup(name: "生产")
        let hosts = [
            Host(name: "web-01", address: "1", username: "r", groupIDs: [prod.id]),
            Host(name: "api-02", address: "2", username: "r", groupIDs: [prod.id])
        ]
        let (viewModel, _) = makeViewModel(hosts: hosts, groups: [prod])

        viewModel.selectedGroupID = prod.id
        viewModel.searchText = "api"

        #expect(viewModel.cards.map(\.name) == ["api-02"])
    }

    @Test("选中的分组 id 悬空时按「全部」处理")
    func danglingSelectionFallsBackToAll() {
        let hosts = [Host(name: "web", address: "1", username: "r")]
        let (viewModel, _) = makeViewModel(hosts: hosts)

        viewModel.selectedGroupID = "gone"

        #expect(viewModel.cards.count == 1)
    }

    @Test("删除当前选中的分组后回到「全部」")
    func deletingSelectedGroupResetsSelection() {
        let prod = HostGroup(name: "生产")
        let (viewModel, _) = makeViewModel(groups: [prod])
        viewModel.selectedGroupID = prod.id

        viewModel.deleteGroup(id: prod.id)

        #expect(viewModel.selectedGroupID == nil)
        #expect(viewModel.groups.isEmpty)
    }

    @Test("重名分组被拒并写入错误消息")
    func rejectsDuplicateGroupName() {
        let (viewModel, groupStore) = makeViewModel(groups: [HostGroup(name: "生产")])

        viewModel.addGroup(" 生产 ")

        #expect(groupStore.groups.count == 1)
        #expect(viewModel.errorMessage == L("已存在同名分组"))
    }

    @Test("新增分组的排序权重递增")
    func newGroupGetsNextSortOrder() {
        let (viewModel, groupStore) = makeViewModel(groups: [HostGroup(name: "生产", sortOrder: 4)])

        viewModel.addGroup("测试")

        #expect(groupStore.groups.map(\.sortOrder).max() == 5)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" \
  -only-testing:ConnTests/ServersViewModelTests 2>&1 | tail -20
```

Expected: 编译失败 —— `ServersViewModel` 没有 `groupStore:` 参数。

- [ ] **Step 3: 改 ServersViewModel**

把 `selectedTag` 换成 `selectedGroupID`，注入 `groupStore`，删除 `severityFirst` 与 `allTags`：

```swift
    private(set) var hosts: [Host] = []
    private(set) var groups: [HostGroup] = []
    private(set) var errorMessage: String?
    var searchText = ""
    var selectedGroupID: String?

    private let hostStore: any HostRepository
    private let groupStore: any HostGroupRepository
    /// 采集调度。View 在 appear/disappear 控制生命周期。
    let monitor: MonitorScheduler

    init(
        hostStore: any HostRepository,
        groupStore: any HostGroupRepository,
        monitor: MonitorScheduler
    ) {
        self.hostStore = hostStore
        self.groupStore = groupStore
        self.monitor = monitor
    }
```

`load()`：

```swift
    func load() {
        do {
            hosts = try hostStore.allHosts()
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch {
            errorMessage = String(format: L("读取主机失败：%@"), error.friendlyDiagnosis)
            hosts = []
            groups = []
        }
    }
```

`delete(_:)` 改 `try? hostStore.delete(id: host.id)`（Task 3 已改）。

`cards` 与筛选：

```swift
    /// 经搜索 / 分组筛选后的健康卡。
    ///
    /// **顺序完全照抄 `HostStore.allHosts()`（`sort_order ASC, name ASC`）**——
    /// 健康状态不参与排序：旧的「故障置顶」会让列表在采集期间持续跳动，
    /// 且未连上的主机会排在已连上的前面。
    var cards: [HealthCard.Model] {
        hosts.filter { matches($0) }.map { card(for: $0) }
    }

    private func matches(_ host: Host) -> Bool {
        let matchesSearch = searchText.isEmpty
            || host.name.localizedCaseInsensitiveContains(searchText)
            || host.address.localizedCaseInsensitiveContains(searchText)
        return matchesSearch && matchesGroup(host)
    }

    /// 选中的分组 id 解析不到现存分组时按「全部」处理（防御分组从其他路径消失）。
    private func matchesGroup(_ host: Host) -> Bool {
        guard let id = selectedGroupID, groups.contains(where: { $0.id == id }) else { return true }
        return host.groupIDs.contains(id)
    }
```

删除整个 `private static func severityFirst` 与 `var allTags`。

`abnormalCount` 保持不变。

分组增删改与错误清理：

```swift
    // MARK: - 分组

    func addGroup(_ name: String) {
        do {
            let trimmed = try GroupListEditor.validate(name: name, against: groups.map(\.name))
            try groupStore.save(HostGroup(
                name: trimmed,
                sortOrder: GroupListEditor.nextSortOrder(after: groups.map(\.sortOrder))
            ))
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func renameGroup(id: String, to name: String) {
        guard var group = groups.first(where: { $0.id == id }) else { return }
        do {
            let others = groups.filter { $0.id != id }.map(\.name)
            group.name = try GroupListEditor.validate(name: name, against: others)
            try groupStore.save(group)
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    /// 删除分组只解除归属，主机本身不受影响（成员行由外键级联清理）。
    func deleteGroup(id: String) {
        do {
            try groupStore.delete(id: id)
            if selectedGroupID == id { selectedGroupID = nil }
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func clearError() {
        errorMessage = nil
    }
```

- [ ] **Step 4: 改 ServersView 的构造调用（保持编译）**

`Conn/Conn/Servers/ServersView.swift` 的 `init`：

```swift
        _viewModel = State(initialValue: ServersViewModel(
            hostStore: dependencies.hostRepository,
            groupStore: dependencies.hostGroupRepository,
            monitor: dependencies.monitor
        ))
```

同时删掉整个 `private var tagFilter: some View { ... }` 属性（它引用了已不存在的 `viewModel.allTags` / `viewModel.selectedTag`，不删就编译不过），以及 `hostsContent` 里的 `if !viewModel.allTags.isEmpty { tagFilter }` 两行。`private func filterChip(title:isSelected:action:)` 暂时保留（Task 10 换成 `GroupFilterBar` 时一并删除），其余不动。

- [ ] **Step 5: 跑测试确认通过**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" \
  -only-testing:ConnTests/ServersViewModelTests 2>&1 | tail -20
```

Expected: 7 条全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: 服务器列表改用默认顺序，ViewModel 接入分组筛选

移除 severityFirst 状态排序（会让列表在采集期间持续跳动，
且未连上的主机排在已连上的前面）与从未可达的标签筛选。"
```

---

### Task 10: ServersView —— 分组筛选条、+ 菜单、toast

**Files:**
- Modify: `Conn/Conn/Servers/ServersView.swift`

**Interfaces:**
- Consumes: Task 7 的 `connToast`、Task 8 的 `GroupFilterBar`、Task 9 的 ViewModel API。
- Produces: 无对外接口。

- [ ] **Step 1: 加分组筛选条**

删除 `tagFilter` 与 `filterChip` 两个私有属性/方法，`hostsContent` 改为：

```swift
    /// 无主机 → 空态垂直居中填满可视区；有主机 → 列表滚动。
    @ViewBuilder
    private var hostsContent: some View {
        if viewModel.hosts.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 一个分组都没有时整行不渲染。
                    if !viewModel.groups.isEmpty {
                        GroupFilterBar(
                            allTitle: L("全部"),
                            groups: viewModel.groups.map {
                                GroupFilterBar.Item(id: $0.id, title: $0.name)
                            },
                            selection: $viewModel.selectedGroupID,
                            onRename: { item in
                                renameTarget = GroupEditRequest(id: item.id, name: item.title)
                                groupNameInput = item.title
                            },
                            onDelete: { item in
                                groupDeleteRequest = GroupEditRequest(id: item.id, name: item.title)
                            }
                        )
                        .padding(.bottom, ConnSpacing.sm)
                    }
                    cards
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
```

在文件顶部（`TerminalRoute` 之后）加请求类型：

```swift
/// 分组重命名 / 删除的呈现请求。
private struct GroupEditRequest: Identifiable {
    let id: String
    let name: String
}
```

`ServersView` 加状态：

```swift
    @State private var isNewGroupPresented = false
    @State private var renameTarget: GroupEditRequest?
    @State private var groupDeleteRequest: GroupEditRequest?
    @State private var groupNameInput = ""
```

- [ ] **Step 2: 工具栏 + 改成菜单**

```swift
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        startAdding()
                    } label: {
                        Label(L("新增服务器"), systemImage: "server.rack")
                    }
                    Button {
                        groupNameInput = ""
                        isNewGroupPresented = true
                    } label: {
                        Label(L("新增分组"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新增"))
            }
        }
```

- [ ] **Step 3: 加三个弹窗与 toast**

在 `.navigationDestination(item: $terminalRoute)` 之后追加：

```swift
        .alert(L("新增分组"), isPresented: $isNewGroupPresented) {
            TextField(L("分组名称"), text: $groupNameInput)
            Button(L("取消"), role: .cancel) {}
            Button(L("保存")) { viewModel.addGroup(groupNameInput) }
                .disabled(groupNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            L("重命名分组"),
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField(L("分组名称"), text: $groupNameInput)
            Button(L("取消"), role: .cancel) { renameTarget = nil }
            Button(L("保存")) {
                if let target = renameTarget {
                    viewModel.renameGroup(id: target.id, to: groupNameInput)
                }
                renameTarget = nil
            }
            .disabled(groupNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            L("删除分组"),
            isPresented: Binding(
                get: { groupDeleteRequest != nil },
                set: { if !$0 { groupDeleteRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                if let request = groupDeleteRequest { viewModel.deleteGroup(id: request.id) }
                groupDeleteRequest = nil
            }
            Button(L("取消"), role: .cancel) { groupDeleteRequest = nil }
        } message: {
            Text(L("删除分组不会删除其中的服务器。"))
        }
        .connToast(message: Binding(
            get: { viewModel.errorMessage },
            set: { if $0 == nil { viewModel.clearError() } }
        ))
```

- [ ] **Step 4: 改删除主机的确认文案**

真删除语义下「可随时重新添加」有误导性。把 `.alert(L("删除主机"), ...)` 的 message 改为：

```swift
        } message: { host in
            Text(String(format: L("「%@」将被永久删除，不影响服务器本身。"), host.name))
        }
```

- [ ] **Step 5: 更新 cards 的动画注释**

```swift
        // 增删主机导致列表变化时平滑滑动而非瞬跳；新卡片淡入。
        // （健康状态已不参与排序，不再有「故障置顶」引发的重排。）
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: viewModel.cards)
```

- [ ] **Step 6: 构建与 lint**

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: `BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: 服务器页分组筛选条与分组管理入口"
```

---

### Task 11: HostFormView —— 分组多选

**Files:**
- Modify: `Conn/Conn/Hosts/HostFormView.swift`
- Modify: `Conn/Conn/Hosts/HostFormViewModel.swift`

**Interfaces:**
- Consumes: Task 5 的 `HostDraft.groupIDs`、`AppDependencies.hostGroupRepository`。
- Produces: `HostFormViewModel.availableGroups: [HostGroup]`

- [ ] **Step 1: ViewModel 读分组**

`HostFormViewModel` 加字段与注入：

```swift
    private(set) var availableGroups: [HostGroup] = []

    private let groupStore: any HostGroupRepository
```

init 增加参数 `groupStore: any HostGroupRepository`，体内 `self.groupStore = groupStore` 与 `availableGroups = (try? groupStore.allGroups()) ?? []`。

保存路径上，丢弃解析不到现存分组的悬空 id（store 层也会过滤，此处是就近防御）：

```swift
        draft.groupIDs = draft.groupIDs.filter { id in
            availableGroups.contains { $0.id == id }
        }
```

放在构造 `Host` 之前。

- [ ] **Step 2: HostFormView 加分组区块**

`HostFormView.init` 里给 `HostFormViewModel(...)` 补 `groupStore: dependencies.hostGroupRepository`。

`Form` 的 section 列表在 `noteSection` 之前插入 `groupSection`：

```swift
            Form {
                pasteSection
                identitySection
                connectionSection
                authSection
                groupSection
                noteSection
                testSection
            }
```

新增：

```swift
    @ViewBuilder
    private var groupSection: some View {
        Section {
            if viewModel.availableGroups.isEmpty {
                Text(L("还没有分组，先用右上角「+」新建。"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .listRowBackground(Color.connSurface)
            } else {
                ForEach(viewModel.availableGroups) { group in
                    Button {
                        toggle(group.id)
                    } label: {
                        HStack {
                            Text(group.name)
                                .foregroundStyle(.connInk)
                            Spacer()
                            Image(systemName: viewModel.draft.groupIDs.contains(group.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .foregroundStyle(viewModel.draft.groupIDs.contains(group.id)
                                    ? Color.connAccent
                                    : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.connSurface)
                }
            }
        } header: {
            Text(L("分组"))
        } footer: {
            if !viewModel.availableGroups.isEmpty {
                Text(L("可多选，也可以不选；不选时归为未分组。"))
            }
        }
    }

    private func toggle(_ groupID: String) {
        if let index = viewModel.draft.groupIDs.firstIndex(of: groupID) {
            viewModel.draft.groupIDs.remove(at: index)
        } else {
            viewModel.draft.groupIDs.append(groupID)
        }
    }
```

- [ ] **Step 3: 构建与 lint**

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: `BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "feat: 主机表单支持多选分组"
```

---

### Task 12: 命令页接入共用组件

命令页改用 `GroupFilterBar` 与 `ConnToast`，分组校验走 `GroupListEditor`，并补上此前缺失的重命名能力。

**Files:**
- Modify: `Conn/Conn/Commands/SnippetsViewModel.swift`
- Modify: `Conn/Conn/Commands/SnippetsView.swift`
- Test: `Conn/ConnTests/SnippetsViewModelTests.swift`

**Interfaces:**
- Consumes: Task 4 的 id 化、Task 6/7/8 的三个共用件。
- Produces: `SnippetsViewModel.renameGroup(id:to:)` / `clearError()`

- [ ] **Step 1: 补失败测试**

在 `SnippetsViewModelTests` 追加：

```swift
    @Test("重名分组被拒并写入错误消息")
    func rejectsDuplicateGroupName() {
        let groupStore = StubSnippetGroupRepository(groups: [SnippetGroup(name: "Docker")])
        let viewModel = SnippetsViewModel(store: StubSnippetRepository(), groupStore: groupStore)
        viewModel.load()

        viewModel.addGroup(" docker ")

        #expect(groupStore.groups.count == 1)
        #expect(viewModel.errorMessage == L("已存在同名分组"))
    }

    @Test("重命名分组不影响成员关系")
    func renameGroupKeepsMembership() {
        let group = SnippetGroup(name: "旧名")
        let snippet = Snippet(title: "ls", command: "ls", groupIDs: [group.id])
        let groupStore = StubSnippetGroupRepository(groups: [group])
        let viewModel = SnippetsViewModel(
            store: StubSnippetRepository(snippets: [snippet]),
            groupStore: groupStore
        )
        viewModel.load()

        viewModel.renameGroup(id: group.id, to: "新名")

        #expect(groupStore.groups.map(\.name) == ["新名"])
        #expect(viewModel.snippets(for: .group(group.id)).map(\.title) == ["ls"])
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" \
  -only-testing:ConnTests/SnippetsViewModelTests 2>&1 | tail -20
```

Expected: 编译失败 —— `renameGroup` 不存在。

- [ ] **Step 3: SnippetsViewModel 改用 GroupListEditor**

把 Task 4 Step 15 里临时写的 `addGroup` / `deleteGroup` 替换为与 `ServersViewModel` 对称的三件套（校验走 `GroupListEditor`），并加 `clearError()`：

```swift
    func addGroup(_ name: String) {
        do {
            let trimmed = try GroupListEditor.validate(name: name, against: groups.map(\.name))
            try groupStore.save(SnippetGroup(
                name: trimmed,
                sortOrder: GroupListEditor.nextSortOrder(after: groups.map(\.sortOrder))
            ))
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func renameGroup(id: String, to name: String) {
        guard var group = groups.first(where: { $0.id == id }) else { return }
        do {
            let others = groups.filter { $0.id != id }.map(\.name)
            group.name = try GroupListEditor.validate(name: name, against: others)
            try groupStore.save(group)
            groups = try groupStore.allGroups()
            errorMessage = nil
        } catch let failure as GroupListEditor.Failure {
            errorMessage = failure.message
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    /// 删除分组只解除归属，命令本身不受影响（成员行由外键级联清理）。
    func deleteGroup(id: String) {
        do {
            try groupStore.delete(id: id)
            load()
        } catch {
            errorMessage = String(format: L("保存失败：%@"), error.friendlyDiagnosis)
        }
    }

    func clearError() {
        errorMessage = nil
    }
```

- [ ] **Step 4: SnippetsView 换成 GroupFilterBar**

删除私有 `filterChip(title:filter:)`，`commandFilters` 改为：

```swift
    private var commandFilters: some View {
        GroupFilterBar(
            allTitle: L("全部"),
            leading: [GroupFilterBar.Item(id: Self.favoritesChipID, title: L("常用"))],
            groups: viewModel.groups.map { GroupFilterBar.Item(id: $0.id, title: $0.name) },
            selection: Binding(
                get: {
                    switch selectedFilter {
                    case .favorites: Self.favoritesChipID
                    case .all: nil
                    case let .group(id): id
                    }
                },
                set: { newValue in
                    switch newValue {
                    case nil: selectedFilter = .all
                    case Self.favoritesChipID: selectedFilter = .favorites
                    case let .some(id): selectedFilter = .group(id)
                    }
                }
            ),
            onRename: { item in
                renameTarget = GroupEditRequest(id: item.id, name: item.title)
                groupNameInput = item.title
            },
            onDelete: { item in
                groupDeleteRequest = GroupEditRequest(id: item.id, name: item.title)
            }
        )
    }

    /// 「常用」不是分组，用一个不可能与 uuid 冲突的哨兵 id 走 GroupFilterBar 的前置 chip。
    private static let favoritesChipID = "__favorites__"
```

把原有的 `GroupDeleteRequest` 替换为与服务器页同名同形的 `GroupEditRequest`（`id` + `name`），并加 `@State private var renameTarget: GroupEditRequest?`、`@State private var groupNameInput = ""`；原 `newGroupName` 统一改用 `groupNameInput`。

分组页的 `groupRow` 的 `Menu` 里补一条重命名：

```swift
                Button {
                    renameTarget = GroupEditRequest(id: group.id, name: group.name)
                    groupNameInput = group.name
                } label: {
                    Label(L("重命名分组"), systemImage: "pencil")
                }
```

- [ ] **Step 5: 加重命名弹窗与 toast**

在既有的 `.alert(L("新增分组"), ...)` 之后追加与 Task 10 Step 3 完全相同的重命名 alert（调用 `viewModel.renameGroup(id:to:)`），并在最外层挂：

```swift
            .connToast(message: Binding(
                get: { viewModel.errorMessage },
                set: { if $0 == nil { viewModel.clearError() } }
            ))
```

`viewModel.errorMessage` 需从 `var` 改为 `private(set) var`，与 `ServersViewModel` 一致。

- [ ] **Step 6: 跑测试与构建**

```bash
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" \
  -only-testing:ConnTests 2>&1 | tail -20
cd Tooling && swiftlint lint --quiet
```

Expected: 全部 PASS；lint 无输出。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: 命令页接入 GroupFilterBar/ConnToast，补上分组重命名"
```

---

### Task 13: 删除密钥前提示受影响主机

改真删除后 `host.key_uuid → ssh_key ON DELETE SET NULL` 这条外键**第一次真正触发**：删掉一把密钥会把引用它的主机 `key_uuid` 置空，用户下次连接才发现连不上且看不出原因。删除前必须报出受影响台数。

**Files:**
- Modify: `Conn/Conn/Keys/KeyManagerViewModel.swift`
- Modify: `Conn/Conn/Keys/KeyManagerView.swift`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/HostStoreTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `delete(id:)`、Task 5 的外键结构。
- Produces: `KeyManagerViewModel.hostCount(using:) -> Int`

- [ ] **Step 1: 写失败测试 —— 级联置空确实发生**

在 `HostStoreTests` 追加：

```swift
    @Test("删除密钥后引用它的主机 key_uuid 被置空")
    func deletingKeyNullsHostReference() throws {
        let database = try AppDatabase.inMemory()
        let hosts = HostStore(database: database)
        let keys = SSHKeyStore(database: database)
        let key = SSHKey(name: "ed25519", kind: .ed25519, publicKey: "ssh-ed25519 AAAA")
        try keys.save(key)
        let host = ConnKit.Host(name: "web", address: "1", username: "root",
                                authKind: .key, keyUUID: key.id)
        try hosts.save(host)

        try keys.delete(id: key.id)

        #expect(try hosts.host(id: host.id)?.keyUUID == nil)
    }
```

- [ ] **Step 2: 跑测试确认它已经通过**

```bash
cd Packages/ConnPackages && swift test --filter HostStoreTests
```

Expected: PASS —— 级联行为由 Task 3 + Task 5 的 schema 提供，此测试锁住它不被回退。若 FAIL，检查 `foreignKeysEnabled`。

- [ ] **Step 3: ViewModel 加使用量查询**

`KeyManagerViewModel` 注入主机仓库：

```swift
    private let hostStore: any HostRepository

    init(
        keyStore: any SSHKeyRepository,
        credentialStore: any CredentialStore,
        hostStore: any HostRepository
    ) {
        self.keyStore = keyStore
        self.credentialStore = credentialStore
        self.hostStore = hostStore
    }

    /// 正在使用该密钥的主机台数。删除前提示用——删除会经外键把这些主机的
    /// `key_uuid` 置空，它们会静默失去认证方式。
    func hostCount(using key: SSHKey) -> Int {
        ((try? hostStore.allHosts()) ?? []).count { $0.keyUUID == key.id }
    }
```

- [ ] **Step 4: View 改成确认弹窗**

`KeyManagerView` 加状态与请求类型：

```swift
    @State private var pendingDelete: SSHKey?
```

`keyList` 的 contextMenu 里，把 `Button(L("删除"), role: .destructive) { viewModel.delete(key) }` 改为：

```swift
                    Button(L("删除"), role: .destructive) { pendingDelete = key }
```

在 `.alert(L("生成 Ed25519 密钥"), ...)` 之后追加：

```swift
        .alert(
            L("删除密钥"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { key in
            Button(L("删除"), role: .destructive) {
                viewModel.delete(key)
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { key in
            let count = viewModel.hostCount(using: key)
            if count > 0 {
                Text(String(
                    format: L("%d 台主机正在使用此密钥，删除后这些主机需要重新选择认证方式。"),
                    count
                ))
            } else {
                Text(L("密钥将被永久删除，无法恢复。"))
            }
        }
```

- [ ] **Step 5: 修构造调用点**

搜 `KeyManagerViewModel(` 并补 `hostStore: dependencies.hostRepository`：

```bash
grep -rn "KeyManagerViewModel(" Conn/Conn
```

- [ ] **Step 6: 构建与 lint**

```bash
cd Packages/ConnPackages && swift test --filter ConnStoreTests
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
cd Tooling && swiftlint lint --quiet
```

Expected: 测试全绿；`BUILD SUCCEEDED`；lint 无输出。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: 删除密钥前提示受影响主机台数

改真删除后 host.key_uuid 的 SET NULL 级联首次真正触发，
不提示会让主机静默失去认证方式。"
```

---

### Task 14: Demo 模式种分组

`DemoData.seedHosts` 只种了 `tags`，而 tags 唯一的用武之地正是被本次替换掉的筛选条。不补分组种子，新功能在 `CONN_DEMO` 截图与冒烟模式下完全不可见。

**Files:**
- Modify: `Conn/Conn/Demo/DemoData.swift`
- Modify: `Conn/Conn/ConnApp.swift`（`demo()` 传入分组仓库）

**Interfaces:**
- Consumes: Task 5 的 `Host.groupIDs`、`AppDependencies.hostGroupRepository`。
- Produces: `DemoData.seedHosts(into:groups:)` 新签名。

- [ ] **Step 1: 改 seedHosts**

```swift
    /// 写入演示主机与分组（含一台故障机，覆盖生产/测试/家用三组与多分组归属）。
    static func seedHosts(into store: HostStore, groups groupStore: HostGroupStore) throws {
        let prod = HostGroup(name: L("生产"), sortOrder: 0)
        let staging = HostGroup(name: L("测试"), sortOrder: 1)
        let home = HostGroup(name: L("家用"), sortOrder: 2)
        for group in [prod, staging, home] {
            try groupStore.save(group)
        }

        let hosts = [
            Host(name: "web-01", address: "10.20.0.11", username: "root",
                 groupIDs: [prod.id], tags: ["prod", "web"], note: "主站 Nginx 入口"),
            Host(name: "api-02", address: "10.20.0.12", username: "deploy",
                 groupIDs: [prod.id], tags: ["prod", "api"]),
            Host(name: "db-master", address: faultHostAddress, username: "root",
                 groupIDs: [prod.id], tags: ["prod", "db"], note: "生产主库，勿直接重启"),
            Host(name: "cache-01", address: "10.20.0.21", username: "deploy",
                 groupIDs: [staging.id], tags: ["staging"]),
            // 同时属于两个分组，用来验证多分组归属。
            Host(name: "worker-1", address: "10.20.0.31", username: "root",
                 groupIDs: [staging.id, prod.id], tags: ["staging", "batch"]),
            Host(name: "home-nas", address: "192.168.1.10", username: "admin",
                 groupIDs: [home.id], tags: ["home"])
        ]
        for host in hosts {
            try store.save(host)
        }
    }
```

> `Host` 的 init 参数顺序是 `... jumpChain, groupIDs, tags, icon, color, note ...`，
> 上面的实参顺序已按此排列。

- [ ] **Step 2: 改调用点**

`ConnApp.swift` 的 `demo()` 里 `try DemoData.seedHosts(into: hostStore)` 改为
`try DemoData.seedHosts(into: hostStore, groups: groupStore)`。

- [ ] **Step 3: 构建并截图验证**

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

用**已启动**的模拟器（`xcrun simctl list devices booted`，不要 boot 新的）：

```bash
DEV=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install "$DEV" "$APP"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
SIMCTL_CHILD_CONN_DEMO=1 xcrun simctl launch "$DEV" "$BUNDLE"
sleep 3
xcrun simctl io "$DEV" screenshot /tmp/servers-groups.png
```

Expected: 截图里服务器列表上方出现「全部 / 生产 / 测试 / 家用」四个 chip，卡片顺序不随连接状态跳动。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "feat: Demo 模式补种服务器分组，覆盖多分组归属"
```

---

### Task 15: i18n 补全与全量验证

**Files:**
- Modify: `Conn/Conn/Localizable.xcstrings`
- Modify: `docs/数据库表设计.md`（如实现中有偏离则同步）

**Interfaces:**
- Consumes: 前 14 个任务引入的全部 `L("…")` 新键。
- Produces: 无。

- [ ] **Step 1: 收集所有新增的 key**

```bash
grep -rhno 'L("[^"]*")' Conn/Conn | sed 's/.*L("//;s/")//' | sort -u > /tmp/keys.txt
python3 - <<'PY'
import json, pathlib
cat = json.loads(pathlib.Path("Conn/Conn/Localizable.xcstrings").read_text())
have = set(cat["strings"])
want = set(pathlib.Path("/tmp/keys.txt").read_text().splitlines())
missing = sorted(w for w in want if w and w not in have)
print("\n".join(missing) or "（无缺失）")
PY
```

- [ ] **Step 2: 补齐 5 种语言**

对上一步列出的每个 key，在 `Conn/Conn/Localizable.xcstrings` 补 `en` / `ja` / `ko` / `zh-Hant` 四种译文（`zh-Hans` 为源语言，key 本身即译文）。本次预期新增：

| key（zh-Hans） | en | ja | ko | zh-Hant |
|---|---|---|---|---|
| `新增` | Add | 追加 | 추가 | 新增 |
| `新增服务器` | Add Server | サーバーを追加 | 서버 추가 | 新增伺服器 |
| `新增分组` | New Group | グループを追加 | 그룹 추가 | 新增分組 |
| `分组名称` | Group Name | グループ名 | 그룹 이름 | 分組名稱 |
| `重命名分组` | Rename Group | グループ名を変更 | 그룹 이름 변경 | 重新命名分組 |
| `删除分组` | Delete Group | グループを削除 | 그룹 삭제 | 刪除分組 |
| `删除分组不会删除其中的服务器。` | Deleting a group does not delete the servers in it. | グループを削除してもサーバーは削除されません。 | 그룹을 삭제해도 서버는 삭제되지 않습니다. | 刪除分組不會刪除其中的伺服器。 |
| `已存在同名分组` | A group with this name already exists | 同じ名前のグループが既にあります | 같은 이름의 그룹이 이미 있습니다 | 已存在同名分組 |
| `分组名称不能为空` | Group name cannot be empty | グループ名を入力してください | 그룹 이름을 입력하세요 | 分組名稱不能為空 |
| `分组` | Groups | グループ | 그룹 | 分組 |
| `可多选，也可以不选；不选时归为未分组。` | Select any number, or none — unselected means ungrouped. | 複数選択も未選択も可能です。未選択の場合は未分類になります。 | 여러 개를 선택하거나 선택하지 않아도 됩니다. 선택하지 않으면 미분류가 됩니다. | 可多選，也可以不選；不選時歸為未分組。 |
| `还没有分组，先用右上角「+」新建。` | No groups yet — create one with “+” in the top right. | グループがありません。右上の「+」から作成してください。 | 아직 그룹이 없습니다. 오른쪽 위 “+”로 만드세요. | 還沒有分組，先用右上角「+」新建。 |
| `「%@」将被永久删除，不影响服务器本身。` | “%@” will be permanently deleted. The server itself is unaffected. | 「%@」を完全に削除します。サーバー自体には影響しません。 | ‘%@’이(가) 영구 삭제됩니다. 서버 자체에는 영향이 없습니다. | 「%@」將被永久刪除，不影響伺服器本身。 |
| `删除密钥` | Delete Key | 鍵を削除 | 키 삭제 | 刪除密鑰 |
| `%d 台主机正在使用此密钥，删除后这些主机需要重新选择认证方式。` | %d hosts use this key. They will need a new authentication method after deletion. | %d 台のホストがこの鍵を使用しています。削除後は認証方式を選び直す必要があります。 | %d대의 호스트가 이 키를 사용 중입니다. 삭제 후 인증 방식을 다시 선택해야 합니다. | %d 台主機正在使用此密鑰，刪除後這些主機需要重新選擇認證方式。 |
| `密钥将被永久删除，无法恢复。` | The key will be permanently deleted and cannot be recovered. | 鍵は完全に削除され、復元できません。 | 키가 영구 삭제되며 복구할 수 없습니다. | 密鑰將被永久刪除，無法復原。 |
| `生产` | Production | 本番 | 프로덕션 | 生產 |
| `测试` | Staging | ステージング | 스테이징 | 測試 |
| `家用` | Home | ホーム | 홈 | 家用 |

- [ ] **Step 3: clean build 后验证多语言**

xcstrings 改动**必须 clean build**，增量构建会继续用旧的字符串目录：

```bash
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug clean build 2>&1 | tail -5
```

再用已启动的模拟器分别以日文、英文启动截图：

```bash
DEV=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_CONN_DEMO=1 xcrun simctl launch "$DEV" "$BUNDLE" -conn.language ja
sleep 3 && xcrun simctl io "$DEV" screenshot /tmp/servers-ja.png
SIMCTL_CHILD_CONN_DEMO=1 xcrun simctl launch "$DEV" "$BUNDLE" -conn.language en
sleep 3 && xcrun simctl io "$DEV" screenshot /tmp/servers-en.png
```

Expected: 两张截图里分组 chip 与「+」菜单文案分别是日文与英文，无中文残留、无 key 原样显示。

- [ ] **Step 4: 全量验证**

```bash
cd Packages/ConnPackages && swift test
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(list(json.load(sys.stdin)["devices"].values())[0][0]["udid"])')" 2>&1 | tail -20
cd Tooling && swiftlint lint --quiet
```

Expected: 包测试全绿；App 测试全绿；lint 无输出。

- [ ] **Step 5: 核对文档与实现一致**

对照 `docs/数据库表设计.md` 第七节，确认最终确实是 9 张表：

```bash
cd Packages/ConnPackages && swift test --filter "SchemaV1Tests/createsAllTables" 2>&1 | tail -5
```

Expected: PASS，表清单为
`host`, `host_group`, `host_group_membership`, `known_host`, `run_history`, `snippet`, `snippet_group`, `snippet_group_membership`, `ssh_key`。

若实现过程中有任何偏离设计文档之处，同步更新 `docs/数据库表设计.md` 与
`docs/superpowers/specs/2026-07-27-server-groups-design.md`。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "chore: 补全 5 语言文案并完成全量验证"
```

---

## 附：实现顺序与构建绿灯

| 任务 | 结束时的验证门 |
|---|---|
| 1–3 | `swift test` + `xcodebuild build` 均绿 |
| 4 | 同上（跨包与 App 两层一次做完） |
| 5 | 同上 |
| 6 | `xcodebuild test -only-testing:ConnTests/GroupListEditorTests` |
| 7–8 | `swift test --filter ConnUITests` |
| 9 | `xcodebuild test -only-testing:ConnTests/ServersViewModelTests` |
| 10–14 | `xcodebuild build` + lint |
| 15 | clean build + 全量测试 + 双语截图 |

Task 4 与 Task 5 都改写 `SchemaV1`，**必须按顺序做**，否则表清单断言会互相打架。
