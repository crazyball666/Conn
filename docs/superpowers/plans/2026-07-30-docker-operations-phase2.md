# Docker 操作（第二期）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Docker 的容器、镜像、卷、网络只读能力上，安全地交付拉取镜像、创建容器、创建/删除卷和网络、可配置 system prune，并统一所有 Docker 写操作的确认、审计与刷新语义。

**Architecture:** `ConnSSH` 新增有最终结果的流式命令抽象，使镜像拉取同时拥有实时输出、超时与退出码语义。`ConnOps` 以纯草稿、校验和 shell 参数编码构造命令；App 侧用一个 `DockerOperationsModel` 串行化全部 Docker 写入，并由 `DockerViewModel` 通过回调执行脱敏审计和定向刷新。表单只编辑草稿，提交前先展示有效配置或强确认页。

**Tech Stack:** Swift 5.10 / iOS 17 / SwiftUI + Observation / Swift Testing / Citadel / SSH CLI / SwiftLint。

设计依据：[2026-07-30-docker-operations-design.md](../specs/2026-07-30-docker-operations-design.md)。

---

## 全局约束

- 执行前在隔离 worktree 中使用 `@superpowers:using-git-worktrees`；本计划不在当前 `main` 工作目录直接实现。
- 先用 `@superpowers:test-driven-development` 走红—绿；每完成一个任务提交一次。不得为了测试而跳过失败前置验证。
- 所有新增用户输入都要作为一个单独 shell argv 以 POSIX 单引号编码；禁止接收整段 Shell 命令。
- `SSHCommandStream` 只服务需要真实终态的短期流式操作。既有日志跟随继续使用 `SSHSession.execStream`，不得悄悄改变日志流的取消语义。
- 所有 Docker 写操作（包括现有容器动作、镜像删除、镜像清理）都必须经一个 `DockerOperationsModel` 共享 gate。没有 `ExecResult` 的结果一律标为未知，不重试。
- Docker pull 在远端启动前持久化脱敏 `.pending` 审计；拿到最终结果时以同一 UUID 原子更新，App 启动会把遗留 pending 恢复为 `.unknown`。不记录环境变量值、extra token、远端输出或拉取日志；unknown 的 `exitCode == nil` 在历史 UI 中显示“结果未知”，不可被当作成功。
- 强确认：删除容器/镜像/卷/网络必须逐字输入资源名；镜像清理和 system prune 必须输入 `PRUNE`。prune 选项改动会清空确认词。
- 用户可见文本用 `L("…")`，在 `Conn/Conn/Localizable.xcstrings` 完成 zh-Hans、en、ja、ko、zh-Hant。
- 当前 SwiftLint 基线为 6 条；从 `Tooling/` 运行 `swiftlint lint --quiet | wc -l`，不得增加。
- 包测试：`cd Packages/ConnPackages && swift test --filter <Suite>`；App 需要以 `xcodebuild` 编译和跑指定的 `ConnTests`。

## 文件结构

| 文件 | 变更责任 |
|---|---|
| `Packages/ConnPackages/Sources/ConnSSH/SSHCommandStream.swift` | 输出流 + 一次最终 `ExecResult` 的协议值类型。 |
| `Packages/ConnPackages/Sources/ConnSSH/SSHTransport.swift` | 给 `SSHSession` 增加带 timeout 的 `execCommandStream`。 |
| `Packages/ConnPackages/Sources/ConnSSHCitadel/CitadelSession.swift` | 同一读取任务转发 stdout/stderr 并产出已知 exit 或未知错误。 |
| `Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift` | 为流式成功、非零退出、分块延迟和中途错误提供确定性夹具。 |
| `Packages/ConnPackages/Sources/ConnOps/ShellArgument.swift` | 单个 POSIX shell 参数的安全编码。 |
| `Packages/ConnPackages/Sources/ConnOps/DockerOperationDraft.swift` | Run、卷、网络、prune 的纯草稿与确定性校验。 |
| `Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift` | pull/run/卷网络增删/system prune 命令构造。 |
| `Packages/ConnPackages/Sources/ConnOps/DockerService.swift` | 对上述命令的 SSH 薄封装与写入超时。 |
| `Conn/Conn/Hosts/DockerOperationsModel.swift` | 全部 Docker 写操作的共享 gate、pull 状态、待确认目标与刷新协调。 |
| `Conn/Conn/Hosts/DockerOperationTypes.swift` | App 层的刷新范围、脱敏审计摘要、确认目标与表单状态。 |
| `Conn/Conn/Hosts/DockerContext.swift` | 注入提示、刷新和重探测闭包，不携带原始命令审计。 |
| `Conn/Conn/Hosts/DockerViewModel.swift` | 创建 Operations，编排定向刷新并注入已脱敏的 run history 依赖。 |
| `Conn/Conn/ConnApp.swift` | App 启动时恢复遗留的 pending Docker pull 审计。 |
| `Conn/Conn/Hosts/DockerContainersModel.swift` / `DockerImagesModel.swift` | 删除各自的写操作执行路径，统一委托 Operations。 |
| `Conn/Conn/Hosts/DockerRunFormView.swift` | 创建容器的结构化字段、重复行编辑与有效配置复核。 |
| `Conn/Conn/Hosts/DockerResourceFormViews.swift` | 创建卷、创建网络两个小表单。 |
| `Conn/Conn/Hosts/DockerPullProgressView.swift` | 拉取镜像的不可误关流式日志页。 |
| `Conn/Conn/Hosts/DockerDestructiveConfirmationView.swift` | 输入确认词的通用 destructive sheet。 |
| `Conn/Conn/Hosts/DockerView.swift` / `ContainerDetailView.swift` | 工具栏、表单路由、行内删除入口，以及移除旧 alert。 |
| `Conn/Conn/Demo/DemoOps.swift` | Phase 2 写命令和流式拉取的演示响应。 |
| `Conn/Conn/Commands/RunHistoryView.swift` | 清晰呈现未知结果，不把 nil exit code 染成成功。 |
| `Conn/Conn/Localizable.xcstrings` | 第二期的五语文案。 |
| `Packages/ConnPackages/Sources/ConnKit/Models/RunHistoryEntry.swift` / `Repositories/RunHistoryRepository.swift` | 定义 pending/known/unknown 审计状态与原子更新接口。 |
| `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV2.swift` / `AppDatabase.swift` | 为已安装数据库迁移 run history 的状态列。 |
| `Packages/ConnPackages/Sources/ConnStore/Records/RunHistoryRecord.swift` / `DAO/RunHistoryStore.swift` | 保存状态，原子完成 audit，并恢复遗留 pending。 |
| `Packages/ConnPackages/Tests/ConnSSHTests/SSHCommandStreamTests.swift` | 流协议的终态、错误、超时与 mock 夹具。 |
| `Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationCommandTests.swift` | 参数转义、草稿校验与 Docker 命令的纯函数测试。 |
| `Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationServiceTests.swift` | Service 超时和精确调用测试。 |
| `Conn/ConnTests/DockerOperationsModelTests.swift` | App 操作 gate、确认、脱敏审计和刷新目标测试。 |
| `Conn/ConnTests/DockerLocalizationTests.swift` | 第二期新增 key 的五语与 format 占位符完整性检查。 |
| `Packages/ConnPackages/Tests/ConnStoreTests/RunHistoryStoreTests.swift` | pending 审计的覆盖、更新与冷启动恢复。 |

现有 `SSHSession` 测试替身也要加 `execCommandStream`：
`Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTestSupport.swift`、`Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`、`Conn/ConnTests/ServersViewModelTests.swift` 的 `GatedSession`，以及 `Conn/ConnTests/DockerModelsTests.swift` 的 `ScriptedSession`。

### Task 1: 建立带终态的流式 SSH 命令契约

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnSSH/SSHCommandStream.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSH/SSHTransport.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSHCitadel/CitadelSession.swift`
- Modify: `Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTestSupport.swift`
- Modify: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`
- Modify: `Conn/ConnTests/ServersViewModelTests.swift`
- Modify: `Conn/ConnTests/DockerModelsTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnSSHTests/SSHCommandStreamTests.swift`

- [ ] **Step 1: 写会失败的流协议测试**

  新建 `SSHCommandStreamTests.swift`，用 `MockSSHTransport` 覆盖四种情况：两块输出后 exit 0、输出后 exit 17、输出后 `SSHError.channelClosed`、超过传入 timeout。断言成功/非零路径的 `await stream.result()` 返回对应 `ExecResult`；后两者抛错且输出保留已经到达的块。

  ```swift
  @Test("流输出与非零退出都可观察")
  func preservesOutputAndExitCode() async throws {
      let stream = try await session.execCommandStream("docker pull bad:tag", timeout: .seconds(30))
      let text = try await collect(stream.output)
      let result = try await stream.result()
      #expect(text == "layer 1\nlayer 2\n")
      #expect(result.exitCode == 17)
  }
  ```

- [ ] **Step 2: 运行测试，确认 API 尚不存在**

  Run: `cd Packages/ConnPackages && swift test --filter SSHCommandStreamTests`

  Expected: 编译失败，提示 `SSHSession` 没有 `execCommandStream`。

- [ ] **Step 3: 定义最小的传输类型和协议方法**

  在新文件加入下面的公开接口；`result()` 必须可重复 await 且始终返回同一最终结果，而非第二次读取远端 stream：

  ```swift
  public struct SSHCommandStream: Sendable {
      public let output: AsyncThrowingStream<Data, Error>
      private let waitForResult: @Sendable () async throws -> ExecResult

      public init(
          output: AsyncThrowingStream<Data, Error>,
          result: @escaping @Sendable () async throws -> ExecResult
      ) {
          self.output = output
          waitForResult = result
      }

      public func result() async throws -> ExecResult { try await waitForResult() }
  }
  ```

  给 `SSHSession` 增加 `execCommandStream(_:timeout:) async throws -> SSHCommandStream`，不要给它“调用旧 `execStream`”的错误默认实现；所有 conformer 必须显式实现。

- [ ] **Step 4: 以一个共享 reader 实现 Citadel 和 Mock**

  Citadel 内部创建一个只消费一次 `client.executeCommandStream` 的任务：每个 stdout/stderr chunk 同时 append 到累计 `Data` 并 yield 到 `output`；正常结束产出 `ExecResult(exitCode: 0, ...)`；`SSHClient.CommandFailed` 转成非零 `ExecResult` 并正常 finish；其余错误同时 finish stream 并让 result task 抛错。用现有 `execRacingTimeout` 包裹等待任务，超时仍须保留 Citadel 的“远端可能继续运行”语义。

  Mock 的 `CommandResponse` 增加可选 `streamChunks`、`streamFailure`、`streamChunkDelay`，让测试能决定块边界和最终结果；没有专用 chunks 时保持旧 `execStream` 的逐行行为。四个既有测试替身（`FlakySession`、`CloseRecordingSession`、`GatedSession`、`ScriptedSession`）实现返回确定性空成功 `SSHCommandStream`，避免 package 与 App 的无关测试在协议变更后无法编译。

- [ ] **Step 5: 运行流协议与回归测试**

  Run: `cd Packages/ConnPackages && swift test --filter 'SSHCommandStreamTests|MockSSHTransportTests|ConnectionManagerTests|MonitorSchedulerTests'`

  Expected: 所选测试全绿，且非零 exit 没有被误归类成 transport 错误。

- [ ] **Step 6: 提交 SSH 流契约**

  ```bash
  git add Packages/ConnPackages/Sources/ConnSSH/SSHCommandStream.swift \
    Packages/ConnPackages/Sources/ConnSSH/SSHTransport.swift \
    Packages/ConnPackages/Sources/ConnSSH/Mock/MockSSHTransport.swift \
    Packages/ConnPackages/Sources/ConnSSHCitadel/CitadelSession.swift \
    Packages/ConnPackages/Tests/ConnSSHTests \
    Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTestSupport.swift \
    Conn/ConnTests/ServersViewModelTests.swift Conn/ConnTests/DockerModelsTests.swift
  git commit -m "feat(ssh): 流式命令返回最终结果"
  ```

### Task 2: 以纯领域类型安全构造第二期 Docker 命令

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnOps/ShellArgument.swift`
- Create: `Packages/ConnPackages/Sources/ConnOps/DockerOperationDraft.swift`
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift`
- Test: `Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationCommandTests.swift`

- [ ] **Step 1: 写失败的参数转义和草稿校验测试**

  覆盖空串、空白、单引号、分号、反引号和 `$()`；断言每个值都是一个单引号 argv。为 `DockerRunDraft` 覆盖缺失镜像、错误端口、重复 `hostPort/protocol`、无效环境变量 key、非绝对 target、空/冲突 option token、合法 command token。再断言 `--name`、`-p`、`--mount`、`--` 被拒绝，而 `--cpus=1` 和 `--add-host` + 值可通过。

  ```swift
  @Test("用户值被视为一个 shell 参数而不是代码")
  func quotesShellMetacharacters() {
      #expect(ShellArgument.quote("$(whoami); x'y") == "'$(whoami); x'\\''y'")
  }
  ```

- [ ] **Step 2: 运行 ConnOps 测试确认失败**

  Run: `cd Packages/ConnPackages && swift test --filter DockerOperationCommandTests`

  Expected: 编译失败，因为 `ShellArgument` 和 `DockerRunDraft` 尚不存在。

- [ ] **Step 3: 实现无 UI、可比较的草稿模型**

  `DockerOperationDraft.swift` 定义 `DockerRunDraft`、`PortBinding`、`EnvironmentEntry`、`MountEntry`（named volume / bind 两种 source）、`RestartPolicy`、`DockerVolumeDraft`、`DockerNetworkDraft`、`DockerSystemPruneOptions` 和 `ValidationError`。所有模型 `Equatable + Sendable`；校验返回 `[ValidationError]`，不在 ConnOps 中调用 UI 本地化。

  `DockerRunDraft` 只接受镜像前 `otherOptionTokens` 与镜像后 `commandTokens` 两段；暴露 `effectiveArguments` 供后续复核页展示。将冲突 flag 做成一个明确的 matcher，匹配 `--name=value` 这类等号形式以及独立 token 形式。

- [ ] **Step 4: 实现命令构造器**

  在 `DockerCommand` 只对动态参数调用 `ShellArgument.quote`，固定字面量不引用。实现：

  ```swift
  public static func pull(reference: String, sudo: Bool) -> String
  public static func run(_ draft: DockerRunDraft, sudo: Bool) -> String
  public static func createVolume(_ draft: DockerVolumeDraft, sudo: Bool) -> String
  public static func removeVolume(name: String, sudo: Bool) -> String
  public static func createNetwork(_ draft: DockerNetworkDraft, sudo: Bool) -> String
  public static func removeNetwork(name: String, sudo: Bool) -> String
  public static func systemPrune(_ options: DockerSystemPruneOptions, sudo: Bool) -> String
  ```

  `systemPrune` 恒含 `-f`，仅在选项开启时加 `-a`、`--volumes`。`run` 依固定顺序输出结构化字段、other options、镜像、command tokens，保证审计复核和测试稳定。

- [ ] **Step 5: 运行测试并做变异检查**

  Run: `cd Packages/ConnPackages && swift test --filter DockerOperationCommandTests`

  Expected: 全绿。临时把 `ShellArgument.quote` 改成直通或删去 `--mount` 冲突规则，确认对应测试会失败后恢复实现。

- [ ] **Step 6: 提交领域命令层**

  ```bash
  git add Packages/ConnPackages/Sources/ConnOps/ShellArgument.swift \
    Packages/ConnPackages/Sources/ConnOps/DockerOperationDraft.swift \
    Packages/ConnPackages/Sources/ConnOps/DockerCommand.swift \
    Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationCommandTests.swift
  git commit -m "feat(ops): 补 Docker 操作命令与安全参数"
  ```

### Task 3: 接通 DockerService 的写入与拉取流

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnOps/DockerService.swift`
- Test: `Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationServiceTests.swift`

- [ ] **Step 1: 写失败的 service 调用测试**

  使用现有 session helper，分别断言：pull 调用 `execCommandStream` 并传五分钟、run/卷网络增删传两分钟、system prune 传五分钟；每个命令等于 `DockerCommand` 的输出。测试 SSH 非零 `ExecResult` 原样回传，而不是 service 层抛错。

- [ ] **Step 2: 运行失败测试**

  Run: `cd Packages/ConnPackages && swift test --filter DockerOperationServiceTests`

  Expected: 缺少相应 `DockerService` 方法。

- [ ] **Step 3: 实现最薄的 service API**

  添加公开的 `pullImage`、`runContainer`、`createVolume`、`removeVolume`、`createNetwork`、`removeNetwork`、`systemPrune`。写入 timeout 常量命名为 `writeTimeout`、`pullTimeout`、`pruneTimeout`；不在 service 做 UI 文案、确认、刷新或审计。

- [ ] **Step 4: 运行 package 回归**

  Run: `cd Packages/ConnPackages && swift test --filter 'DockerOperationServiceTests|DockerServiceResourceTests|DockerParserTests'`

  Expected: 所选 Docker service / parser 测试全绿。

- [ ] **Step 5: 提交 service 接线**

  ```bash
  git add Packages/ConnPackages/Sources/ConnOps/DockerService.swift \
    Packages/ConnPackages/Tests/ConnOpsTests/DockerOperationServiceTests.swift
  git commit -m "feat(ops): 接通 Docker 第二期写操作"
  ```

### Task 4: 建共享操作模型、强确认、脱敏审计和定向刷新

**Files:**
- Create: `Conn/Conn/Hosts/DockerOperationTypes.swift`
- Create: `Conn/Conn/Hosts/DockerOperationsModel.swift`
- Modify: `Conn/Conn/Hosts/DockerContext.swift`
- Modify: `Conn/Conn/Hosts/DockerViewModel.swift`
- Modify: `Conn/Conn/Hosts/DockerContainersModel.swift`
- Modify: `Conn/Conn/Hosts/DockerImagesModel.swift`
- Modify: `Conn/Conn/ConnApp.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Models/RunHistoryEntry.swift`
- Modify: `Packages/ConnPackages/Sources/ConnKit/Repositories/RunHistoryRepository.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV2.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/Records/RunHistoryRecord.swift`
- Modify: `Packages/ConnPackages/Sources/ConnStore/DAO/RunHistoryStore.swift`
- Modify: `Conn/Conn/Commands/RunHistoryView.swift`
- Test: `Conn/ConnTests/DockerOperationsModelTests.swift`
- Test: `Conn/ConnTests/DockerModelsTests.swift`
- Modify Test: `Packages/ConnPackages/Tests/ConnStoreTests/RunHistoryStoreTests.swift`

- [ ] **Step 1: 写失败的 Operations 行为测试**

  用可控 `DockerContext` fake 和 Mock SSH 覆盖以下行为：

  - 第二项写操作在第一项飞行中被拒绝，且不会发第二条命令；
  - 容器 start/stop/restart/remove、image remove/prune 都经同一 gate；
  - known success 和 known nonzero 都调用相应 `DockerRefreshScope`，transport/timeout unknown 不自动刷新；
  - unknown 审计 `exitCode == nil`，且摘要不含 `SECRET=value`、extra token、stdout；
  - pull 在请求 `DockerService.pullImage` **之前**写入同一 UUID 的 `.pending` 审计，已知终态以该 UUID 更新为 `.known`，流中断更新为 `.unknown`，不得再插入第二条记录；
  - 删除确认必须精确输入目标名，prune 必须为 `PRUNE`，切换 prune option 会复位确认词；
  - pull 收到 chunk，最终非零成为 known failure；流中断保留日志并成为 unknown。

  扩展既有 `RunHistoryStoreTests`，覆盖同一 UUID 的 pending → known 覆盖、调用 `recoverPending()` 后遗留 pending 变为 unknown。另在该 suite 或 `AppDatabaseTests` 用真实 `DatabaseQueue` 先只注册/执行 `SchemaV1`、插入 `exit_code == nil` 的旧记录，再交给 `AppDatabase(queue)` 运行 V2，断言该行迁移为 unknown；不能用已经直达最新 schema 的 `AppDatabase.inMemory()` 冒充升级测试，也不能只验证 mock 调用。

- [ ] **Step 2: 运行 App 测试确认失败**

  Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerOperationsModelTests`

  Expected: 编译失败，因为 Operations 类型和 context 注入尚不存在。若没有该模拟器，先选一个已 boot 的 iPhone simulator，不要创建新设备。

- [ ] **Step 3: 定义 App 层操作类型与 Context 注入点**

  `DockerOperationTypes.swift` 定义：

  ```swift
  struct DockerRefreshScope: OptionSet, Sendable { ... }
  enum DockerPendingDestructiveAction: Identifiable, Equatable { ... }
  struct DockerAuditSummary: Equatable, Sendable { let text: String }
  enum DockerOperationResult: Equatable { case success, failure(String), unknown(String) }
  ```

  `DockerContext` 去除能泄漏完整命令/输出的 `audit` 闭包，新增 `refresh: (DockerRefreshScope) async -> Void`。`DockerOperationsModel` 构造时显式注入 `hostUUID` 和 `RunHistoryRepository`，只把 `DockerAuditSummary` 转成脱敏 `RunHistoryEntry`；不得再将完整 `ExecResult`、原始命令或 stdout 交给外壳审计。

  在 `ConnKit` 增加 `RunHistoryState: String, Codable, Sendable, Equatable`（`.pending`、`.known`、`.unknown`）及 `RunHistoryEntry.state`；`isSuccess` 仅在 `state == .known && exitCode == 0` 时为真。`RunHistoryRepository` 增加明确的 `update(_ entry:)`（按 UUID 覆盖）和 `recoverPending()` 接口。`SchemaV2` 只能新增迁移：给 `run_history` 添加非空 `state` 文本列（默认 `known`），再把历史 `exit_code IS NULL` 的行更新为 `unknown`；在 `AppDatabase.migrator` 追加 V2，绝不修改 V1。`RunHistoryRecord` 映射该列；`RunHistoryStore.update` 在单个 writer transaction 内按 UUID 更新并提供批量 pending → unknown 恢复。

  `AppDependencies.live()` 与 `.demo()` 都先创建一个 `RunHistoryStore`，在装配依赖前同步调用一次 `recoverPending()`，然后把同一实例注入依赖容器。恢复失败应沿用数据库初始化的失败路径，不能静默跳过并把 pending 误显示为成功。

- [ ] **Step 4: 实现 Operations，并迁移已有动作**

  `DockerOperationsModel` 在 `@MainActor` 下维护 `activeOperation`，所有入口先同步取得 gate、以 `defer` 释放。它接收草稿或现有资源，调用 Task 3 的 service，分类 result 并通过 context 发 refresh / report。

  pull 先将脱敏摘要作为 `.pending` 同步 `record`，**成功记录后才允许调用** `DockerService.pullImage`；终态到达后对同一个 UUID 做一次 `.known` 更新（包括非零 exit）；流读取/超时/transport 异常则以同一个 UUID 更新 `.unknown` 和 `nil` exit。若 pending 初始写入失败，向用户报告本地审计失败且不启动远端 pull，避免产生无法恢复的无锚点操作。非 pull 写操作只在取得已知 `ExecResult` 后记录 `.known`，未获得终态的远端调用记录 `.unknown`，本地草稿校验失败不审计。

  在 ViewModel 中**先创建 Operations，再创建四个资源模型**，并以弱捕获的 `refresh` 闭包实现 `refresh(scope:)`；按 scope 静默 reload 容器、镜像（连同 usage）、卷、网络和磁盘占用。可用性重新探测只能在 gate 空闲时重建所有模型。

  删除 `DockerContainersModel.perform/confirmRemoval` 与 `DockerImagesModel.confirmRemoval/prune` 的直接 service 调用；改成面向 Operations 的小转发，维持详情页调用点的最小改动。`RunHistoryEntry.isSuccess` 改为仅 `exitCode == 0`，历史 UI 对 nil 显示本地化“结果未知”。

- [ ] **Step 5: 运行 model、历史与既有 Docker 回归测试**

  Run:

  ```bash
  cd Packages/ConnPackages && swift test --filter RunHistoryStoreTests
  cd ../.. && xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerOperationsModelTests -only-testing:ConnTests/DockerModelsTests
  ```

  Expected: 全绿；known nonzero 不是 unknown，nil exit code 不是绿色成功；冷启动恢复没有留下 pending。

- [ ] **Step 6: 提交操作协调层**

  ```bash
  git add Conn/Conn/Hosts/DockerOperationTypes.swift \
    Conn/Conn/Hosts/DockerOperationsModel.swift Conn/Conn/Hosts/DockerContext.swift \
    Conn/Conn/Hosts/DockerViewModel.swift Conn/Conn/Hosts/DockerContainersModel.swift \
    Conn/Conn/Hosts/DockerImagesModel.swift Conn/Conn/ConnApp.swift \
    Conn/Conn/Commands/RunHistoryView.swift \
    Conn/ConnTests/DockerOperationsModelTests.swift Conn/ConnTests/DockerModelsTests.swift \
    Packages/ConnPackages/Sources/ConnKit/Models/RunHistoryEntry.swift \
    Packages/ConnPackages/Sources/ConnKit/Repositories/RunHistoryRepository.swift \
    Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV2.swift \
    Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift \
    Packages/ConnPackages/Sources/ConnStore/Records/RunHistoryRecord.swift \
    Packages/ConnPackages/Sources/ConnStore/DAO/RunHistoryStore.swift \
    Packages/ConnPackages/Tests/ConnStoreTests/RunHistoryStoreTests.swift
  git commit -m "feat(docker): 统一操作确认、审计与刷新"
  ```

### Task 5: 创建第二期表单与不可误关的拉取进度页

**Files:**
- Create: `Conn/Conn/Hosts/DockerRunFormView.swift`
- Create: `Conn/Conn/Hosts/DockerResourceFormViews.swift`
- Create: `Conn/Conn/Hosts/DockerPullProgressView.swift`
- Create: `Conn/Conn/Hosts/DockerDestructiveConfirmationView.swift`
- Test: `Conn/ConnTests/DockerOperationsModelTests.swift`

- [ ] **Step 1: 为草稿到 UI 的映射补失败测试**

  向 App 测试加入：每种 repeatable row 删除/增加后仍保持草稿顺序；非法草稿禁用“继续”；有效草稿会把结构化字段、other option tokens、command tokens 不改变地交给 Operations；高风险配置检测 `--privileged`、host network、`/var/run/docker.sock` 与 `/` bind。

  同时覆盖 pull 展示状态：`active` 时 `canDismissPull == false`，只有 `.known` 或 `.unknown` 终态才变为 `true`；关闭请求在 active 状态不得清空 Operations 持有的 presentation，避免 route 被异步或手势写成 nil。

- [ ] **Step 2: 运行测试确认表单 API 缺失**

  Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerOperationsModelTests`

  Expected: 失败，因表单草稿辅助或高风险检测尚未实现。

- [ ] **Step 3: 实现容器、卷、网络表单**

  `DockerRunFormView` 用 `NavigationStack + Form`，分为基本、网络、端口、环境变量、挂载、重启策略、高级选项、启动命令。端口、环境变量、挂载与 tokens 均使用稳定 UUID 标识的行模型，绝不能用数组 offset 作为可编辑数据身份。网络与具名卷使用当前列表的 picker；绑定挂载可直接填写源路径。提交先展示只读的有效配置复核页；以 `KEY=••••` 隐去环境变量值，同时用 badge 标出高风险配置。

  `DockerResourceFormViews` 为卷和网络使用独立的小 `Form`，默认 `local` / `bridge`，网络提供 internal、attachable；额外参数也逐 token 编辑并经同一 `ShellArgument` 路径。表单只持有 `@State` 草稿，实际执行交给 Operations。

- [ ] **Step 4: 实现 pull 与 typed destructive 页面**

  `DockerPullProgressView` 从 Operations 观察 logs / result，且只由 Task 6 的 `fullScreenCover(item:)` 呈现；活动期间使用 `.interactiveDismissDisabled(true)`、不提供 NavigationStack 的返回按钮、toolbar cancel 或取消命令。它不创建自己的 `.task`。已知完成或 unknown 后才显示“完成”按钮；该按钮通过 Operations 的终态 API 关闭 presentation。视图不能直接将 active pull 的 binding 写成 nil。

  `DockerDestructiveConfirmationView` 根据 pending action 显示影响、资源名和 `TextField`；只在 `operations.canConfirm(input:)` 时启用 destructive button。prune 开关绑定 Operations，任何更改必须清空 confirmation input。

- [ ] **Step 5: 运行 App 表单/model 测试**

  Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerOperationsModelTests`

  Expected: 全绿；复核后仍保留 token 顺序，强确认不能被空字符串或旧的 prune 确认词绕过。

- [ ] **Step 6: 提交表单组件**

  ```bash
  git add Conn/Conn/Hosts/DockerRunFormView.swift \
    Conn/Conn/Hosts/DockerResourceFormViews.swift \
    Conn/Conn/Hosts/DockerPullProgressView.swift \
    Conn/Conn/Hosts/DockerDestructiveConfirmationView.swift \
    Conn/ConnTests/DockerOperationsModelTests.swift
  git commit -m "feat(docker): 新增创建与强确认表单"
  ```

### Task 6: 将操作入口接入 Docker 四分段与详情页

**Files:**
- Modify: `Conn/Conn/Hosts/DockerView.swift`
- Modify: `Conn/Conn/Hosts/ContainerDetailView.swift`
- Modify: `Conn/Conn/Hosts/VolumeDetailView.swift`
- Modify: `Conn/Conn/Hosts/NetworkDetailView.swift`
- Modify: `Conn/Conn/Hosts/ImageDetailView.swift`
- Test: `Conn/ConnTests/DockerModelsTests.swift`

- [ ] **Step 1: 写失败的入口状态测试**

  扩展 model 测试，断言 Docker 不可用时创建/删除入口不可触发；预置网络永不构造删除 action；仅未使用卷/网络构造删除 action；操作进行时所有写入口禁用但当前列表仍可阅读。

- [ ] **Step 2: 运行测试确认 UI 路由/入口状态未实现**

  Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerModelsTests`

- [ ] **Step 3: 改造 DockerView 的路由和工具栏**

  建立 `OperationSheet` 路由：container create、image pull form、volume create、network create、destructive confirmation。容器、镜像、卷、网络分段工具栏依次展示创建/拉取按钮；镜像菜单把旧的直接 `image prune` 替换为 Operations 的 typed confirmation。删除容器/镜像的旧 `.alert` 必须移除，改呈现统一 confirmation sheet。

  pull form 提交后，把 Operations 的 pull presentation 作为 `DockerView` 顶层独立的 `fullScreenCover(item:)`；**不得**把进度页放进 `NavigationStack` path、`OperationSheet` 或普通 sheet。cover 的 binding setter 在 `activeOperation` 存在时忽略外部 nil 写入，只有 Operations 收到终态后的完成动作才能清空它。这样侧滑、导航返回、分段切换和 SwiftUI 的意外 route 重置都不能离开活动 pull；App 被系统终止仍由 Task 4 的 pending 恢复承担，如实显示 unknown。

  对卷和网络使用整行命中区的 menu 或 swipe action；无“未使用”标记的卷/网络不显示删除。选项一经提交即让 Operations 处理，不在 View 内直调 service。

- [ ] **Step 4: 迁移详情页的现有动作入口**

  `ContainerDetailView` 的 start/stop/restart/remove 必须使用同一个 Operations，并移除自己的 `showRemoveConfirm` alert；镜像详情若保留删除入口也走同一 action。卷/网络详情与列表遵循相同预置/未使用删除策略。确保 push 导航仍只使用局部 route，不能重用 `DockerView.route`。

- [ ] **Step 5: 运行 Docker App 回归和编译**

  Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerModelsTests && xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug`

  Expected: Docker model 测试与 App 编译成功。

- [ ] **Step 6: 提交 UI 接线**

  ```bash
  git add Conn/Conn/Hosts/DockerView.swift Conn/Conn/Hosts/ContainerDetailView.swift \
    Conn/Conn/Hosts/VolumeDetailView.swift Conn/Conn/Hosts/NetworkDetailView.swift \
    Conn/Conn/Hosts/ImageDetailView.swift Conn/ConnTests/DockerModelsTests.swift
  git commit -m "feat(docker): 接入第二期操作入口"
  ```

### Task 7: 补演示、五语文案和 catalog 完整性护栏

**Files:**
- Modify: `Conn/Conn/Demo/DemoOps.swift`
- Modify: `Conn/Conn/Localizable.xcstrings`
- Create: `Conn/ConnTests/DockerLocalizationTests.swift`
- Test: `Conn/ConnTests/DockerLocalizationTests.swift`

- [ ] **Step 1: 写失败的 catalog 完整性测试**

  测试从 `#filePath` 定位 App catalog，解析 JSON，并枚举本期的新 Docker keys。每个 key 必须有 `en`、`ja`、`ko`、`zh-Hant` 的 `translated` string unit；含 `%@` / `%d` 的译文与源文拥有完全相同的占位符多重集合。

- [ ] **Step 2: 运行测试确认新 key 尚未完整翻译**

  Run: `xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerLocalizationTests`

  Expected: 新建测试/文案缺失而失败。

- [ ] **Step 3: 扩展确定性 DemoOps 响应**

  为 `docker pull` 返回多个可读 chunk，另备一个非零失败镜像；为 run、卷/网络 create/remove、system prune 返回明确 `CommandResponse`。分支顺序保持“具体命令在宽泛匹配之前”，避免 `docker network create` 被 `network ls` 分支吞掉。演示环境不需要真的更改后续 JSON 列表，但要让成功/失败/unknown UI 均能显示。

- [ ] **Step 4: 添加全部第二期文案与五语翻译**

  将表单标题、字段名、添加/删除行、有效配置复核、高风险提示、拉取状态、已知失败、结果未知、强确认、prune 范围、审计未知状态全部加入 `Conn/Conn/Localizable.xcstrings`。不硬编码新用户可见文本；服务器 stderr 保持原样。

- [ ] **Step 5: 运行 localization、lint 和干净构建**

  Run:

  ```bash
  xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerLocalizationTests
  cd Tooling && swiftlint lint --quiet | wc -l
  cd .. && xcodebuild clean build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug
  ```

  Expected: catalog 测试通过，lint 结果不超过 6，clean build 成功。xcstrings 改动必须走 clean build，避免增量编译继续使用旧 catalog。

- [ ] **Step 6: 提交演示与本地化**

  ```bash
  git add Conn/Conn/Demo/DemoOps.swift Conn/Conn/Localizable.xcstrings \
    Conn/ConnTests/DockerLocalizationTests.swift
  git commit -m "feat(docker): 补第二期演示与本地化"
  ```

### Task 8: 端到端回归、模拟器冒烟与交付核验

**Files:**
- Modify only if verification exposes a scoped defect; otherwise no source changes.

- [ ] **Step 1: 跑完整 package 测试**

  Run: `cd Packages/ConnPackages && swift test`

  Expected: 所有 package suites 成功；任何 `SSHSession` conformer 都已适配新方法。

- [ ] **Step 2: 跑 App 的 Docker、历史与本地化测试**

  Run:

  ```bash
  cd Packages/ConnPackages && swift test --filter RunHistoryStoreTests
  cd ../.. && xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ConnTests/DockerModelsTests -only-testing:ConnTests/DockerOperationsModelTests -only-testing:ConnTests/DockerLocalizationTests
  ```

  Expected: 全绿，无 flaky sleep 或未等待的异步任务。

- [ ] **Step 3: 做演示模式 UI 冒烟**

  使用现有 `Tooling/run_sim.sh` 和 `CONN_DEMO=1` 启动 App；依次检查容器创建表单、有效配置复核、镜像 pull 日志、卷/网络创建、typed 删除、prune 选项和“结果未知”。pull 仍 active 时分别尝试下滑关闭、导航返回和切换 Docker 分段，确认都不能关闭进度页；到 known/unknown 终态后确认“完成”可关闭。若自动化点击无法覆盖表单，添加仅 DEBUG 的确定性 smoke route，而不是在发行代码保留测试开关。

- [ ] **Step 4: 验证真实 Docker 主机的最小矩阵**

  在用户提供或现有 SSH Docker 测试机上手工验证：普通 docker 组用户、仅 `sudo -n` 用户、权限不足用户；拉取一个小镜像、创建/删除一个临时命名容器/卷/网络，并确认旧 Docker 的 `system df` 仍安全降级。所有真实写操作使用唯一 `conn-smoke-*` 前缀并在测试后由用户确认后清理。

- [ ] **Step 5: 最终 build、lint 与状态检查**

  Run:

  ```bash
  xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug
  cd Tooling && swiftlint lint --quiet | wc -l
  cd .. && git status --short
  ```

  Expected: `BUILD SUCCEEDED`，lint 不超过 6，状态只包含计划内变更。

- [ ] **Step 6: 提交最终修复并请求代码审阅**

  如验证有修复，使用聚焦提交；随后使用 `@superpowers:requesting-code-review` 对第二期整体变更进行审阅。没有修复时不制造空提交。

## 交付验收表

| 验收项 | 证明 |
|---|---|
| Pull 有真实输出、已知 exit 和未知结果 | `SSHCommandStreamTests` + pull model 测试。 |
| 所有 Docker 写操作串行 | Operations gate 测试和旧容器/镜像动作迁移测试。 |
| 用户输入不能逃逸 shell | `ShellArgument` 的 metacharacter 夹具与命令快照。 |
| 创建容器覆盖结构化字段和手动参数 | 草稿校验、有效配置复核、UI 冒烟。 |
| 删除和清理不可误触 | typed confirmation 测试，prune option 重置测试。 |
| 审计不会存秘密且 unknown 不误报成功 | audit/RunHistory 单测和 pending 冷启动恢复测试。 |
| 活动 pull 不可意外离开 | full-screen cover 路由测试与模拟器手势/返回冒烟。 |
| UI、i18n 与工程完整性 | catalog 测试、lint、clean build、模拟器冒烟。 |
