# Conn Phase 7–9 实现计划：监控 · Docker/日志 · 片段

> **执行说明**：本计划由主会话内联执行（非子代理）。每个 Phase 交付「可编译 + host 单测绿 + 接入 UI」的纵向切片，分别提交。最后由用户统一验收。

**目标**：让已搭好的仪表盘/指标环显示真实数据（P7），在手机上管容器 + 跟日志排错（P8），一键执行预设运维命令（P9）。

**架构**：新增三个纯 Swift 领域包 `ConnMonitor` / `ConnOps` / `ConnRunner`（均只依赖 ConnKit + ConnSSH，零 UIKit → 可在 macOS host 上 `swift test`）。解析器/计算器是 host 可测核心；调度与 UI 在 App 层接入。演示数据经 `MockSSHTransport.dynamicResponder` 闭包注入（App 层生成，保持 ConnSSH 解耦），Phase 10 演示模式复用。

**技术栈**：Swift 5 语言模式（Xcode 26）、Observation `@Observable @MainActor`、GRDB（Schema v2）、Swift Concurrency（TaskGroup + actor）。

## 全局约束（每个任务隐含）

- iOS 17.0 基线；host 侧 macOS 15。
- 颜色只走 ConnUI 令牌（SwiftLint `no_hardcoded_hex`）；禁遥测 SDK。
- 避免 `!`（`force_unwrapping` opt-in 已启用）；函数体 ≤60 行告警；文件 ≤500 行告警；行宽 ≤140。
- 领域层不依赖 ConnUI；ConnUI 不依赖 ConnKit（Feature 层做映射）。
- 写操作（容器启停、片段执行）入 `run_history` 审计。
- 只读优先：日志过滤为客户端 grep，不改远端命令。

## 相对方案的取舍（明确记录）

1. **不做 capability probe 缓存**：改用「单趟脚本内同时跑 GNU `ps` 与 BusyBox `top`，解析器择优」——一趟往返达成同样的跨发行版兼容（方案 §4.3 的兼容目标），更简单。核心指标（CPU/内存/负载/磁盘/网络）全部读 `/proc` + `df -P -k`，Alpine/BusyBox 同样具备，无需分支。
2. **`MonitorScheduler` 用 `@MainActor @Observable` 而非 actor**：与 App 既有 VM 模式一致（DashboardViewModel 等皆如此），SwiftUI 观测零样板；网络 I/O 经 `MetricCollector`（actor）与 `ConnectionManager`（actor）在挂起点离开主线程。
3. **历史曲线（Swift Charts）不做**：PRD §8 列为专业版（💰）。v1.0 免费版只呈现实时读数；仍持久化最近样本到 `metric_sample` 供离线快照（PRD §6 离线要求）。
4. **批量执行 / App Intents 不做**：PRD 明列 v1.5💰。
5. **拨测（HTTP/TCP/ICMP）**：实现 HTTP + TCP（`URLSession` 证书到期 + `Network.framework` 计时）；ICMP(SimplePing) 顺延（保底集不含拨测，PRD 风险表可降级项）。

---

## Phase 7 — 监控采集（ConnMonitor）

**文件**
- 新包 `Sources/ConnMonitor/`：`CollectionScript.swift`（sentinel + 单趟脚本）、`MetricParser.swift`（分段解析）、`CPUCalculator.swift`（两次 /proc/stat 差分）、`RemoteProcess.swift`、`HostMetrics.swift`（样本 + 进程 + cpuReady + severity）、`MetricCollector.swift`（actor，持上次 CPU 快照）、`MonitorScheduler.swift`（@MainActor @Observable，仪表盘 30s / 详情 3s / 并发 4）、`HealthEvaluator.swift`、`ProbeService.swift`（HTTP/TCP）。
- `Sources/ConnKit/Repositories/MetricRepository.swift`（协议）。
- `Sources/ConnStore/`：`Migrations/SchemaV2.swift`（metric_hourly）、`DAO/MetricStore.swift`、`Records/MetricRecord.swift`。
- 测试：`Tests/ConnMonitorTests/`（GNU + BusyBox fixture、CPU 差分、health 阈值）、`Tests/ConnStoreTests/MetricStoreTests.swift`。
- App：`Dashboard/DashboardViewModel.swift`（并入 live metrics）、`Dashboard/DashboardView.swift`（路由到详情）、`Hosts/HostDetailView.swift`（实时环 + 进程表 + kill）、`ConnApp.swift`（注入 scheduler + collector）。

**验收（方案 §4.3）**
- [ ] 解析器单测覆盖 GNU/BusyBox 两套 fixture（数值正确）。
- [ ] 连真实 Docker 矩阵，指标与 `top`/`free` 人工比对误差 <5%。
- [ ] 断连主机在仪表盘显示灰/错误态，不阻塞其他主机刷新。
- [ ] 单机详情 3s 刷新；仪表盘 30s；页面不可见即停。

## Phase 8 — Docker + 日志中心（ConnOps）

**文件**
- 新包 `Sources/ConnOps/`：`ContainerInfo.swift`、`DockerCommand.swift`（命令构造）、`DockerParser.swift`（`ps -a --format {{json .}}` + `stats` JSON 合并）、`DockerService.swift`（列表/启停/rm/日志流 + 无权限探测）、`LogSource.swift`（journalctl/文件/容器 + 预设探测）、`LogHighlighter.swift`（error/warn 正则分级）、`LogLine.swift`、`LogRing.swift`（5000 行环）。
- 测试：`Tests/ConnOpsTests/`（docker JSON fixture、高亮规则、无 systemd 降级）。
- App：`Hosts/DockerView.swift`、`Hosts/DockerViewModel.swift`、`Hosts/LogCenterView.swift`、`Hosts/LogCenterViewModel.swift`；接入 `HostDetailView` Docker/日志段。
- ConnUI：`Components/ConnLogLineView.swift`（可选，若复用现有足够则免）。

**验收（方案 §4.4）**
- [ ] `docker ps` JSON 解析 + stats 合并渲染；启停/重启/rm（rm 强确认）入 run_history。
- [ ] 非 root 无 docker 组权限 → 引导文案（探测 `sudo -n docker ps`）。
- [ ] 日志跟随（journalctl/文件 tail -F/容器 logs -f）走 execStream；error/warn 高亮；客户端关键词过滤；暂停跟随。
- [ ] 无 journalctl 系统 → 降级只展示文件源。

## Phase 9 — 片段库与执行（ConnRunner）

**文件**
- 新包 `Sources/ConnRunner/`：`SnippetRunner.swift`（render → 静默 exec / 终端；danger 确认；写 history）、`RunOutcome.swift`、`BuiltinSnippets.swift`（加载 JSON 资源）。资源 `Resources/builtin-snippets.json`（20 条）。
- `Sources/ConnKit/Repositories/SnippetRepository.swift` + `Models/RunHistoryEntry.swift`。
- `Sources/ConnStore/`：`DAO/SnippetStore.swift`、`DAO/RunHistoryStore.swift`、`Records/SnippetRecord.swift`、`Records/RunHistoryRecord.swift`。
- 测试：`Tests/ConnRunnerTests/`（render 转义、danger 拦截）、`Tests/ConnStoreTests/SnippetStoreTests.swift`。
- App：`Commands/SnippetsView.swift` + VM、`Commands/SnippetFormView.swift`、`Commands/VariableFormSheet.swift`、`Commands/RunHistoryView.swift`；`RootTabView` 接第 4 Tab；首启导入内置片段。

**验收（方案 §4.6 / PRD §5.6）**
- [ ] `{{name}}`/`{{name:default}}` 变量表单填参；`\{\{` 转义单测覆盖（已在 ConnKit）。
- [ ] 静默执行结果卡（stdout + exit code）/ 进终端两种目标。
- [ ] danger 片段执行前强确认；内置模板 20 条首启可跳过导入。
- [ ] 执行写 run_history，可在历史视图查看。

## 演示数据（贯穿三阶段，Phase 10 复用）

- `MockSSHTransport.Behavior.dynamicResponder`：`(command, endpoint) -> CommandResponse?`。
- App `AppDependencies.demo()`：注入 responder，用 ConnMonitor/ConnOps 生成 /proc、docker、日志假数据；含一台「故障机」（高 CPU/内存 → 红）。
- 启用：`CONN_DEMO=1` 环境变量（对齐既有 `CONN_SMOKE_*`）；Phase 10 升级为 Me 页开关。
