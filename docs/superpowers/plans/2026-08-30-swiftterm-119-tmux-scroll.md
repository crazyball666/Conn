# SwiftTerm 1.19 与 tmux 滚动稳定性 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 vendored SwiftTerm 升级到稳定版 1.19.0，并消除 tmux 滚动被无关状态 revision 中断的竞态。

**Architecture:** 以官方 `v1.19.0` 完整源码为 vendor 基线，重放 Conn 的 Host 交互、安全和输入补丁，并用固定 BuildInfo 避免父仓库污染版本。滚动层用仅包含真实滚动条件的签名固定手势；tmux 历史与 Copy Mode 在异步执行边界重新校验目标、attachment、freshness 和 mode，而不依赖易漂移的全局 revision。

**Tech Stack:** Swift 6、Swift Package Manager、SwiftTerm、UIKit/SwiftUI、Swift Testing、XCTest/XCUITest、tmux Control Mode。

---

## 文件结构

- `Packages/Vendor/SwiftTerm/`：官方 v1.19.0 完整基线与 Conn 最小 vendor 补丁。
- `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/SwiftTermBuildInfo.swift`：固定的 vendor 来源版本，不读取 Conn Git 状态。
- `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/TerminalHostInteraction.swift`：Host 协议状态与安全交互边界，增加 Alternate Scroll Mode。
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteraction.swift`：滚动路由输入、签名与 token。
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteractionController.swift`：手势固定和签名失效策略。
- `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`：历史任务签名、发布校验、1007 路由和任务取消。
- `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalInteraction.swift`：移除只读历史和滚动请求中的全局 expected revision。
- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxInteraction.swift`：历史读取按目标/attachment 校验并返回真实读取 revision。
- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProviderControlRuntimeRegistry.swift`：将无 revision 的 mode scroll 请求交给 Hub。
- `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`：执行槽内原子校验目标、attachment、freshness 和 mode capability。
- `Packages/ConnPackages/Tests/ConnTerminalTests/`、`Packages/ConnPackages/Tests/ConnMultiplexerTests/`：竞态与路由单元测试。
- `Conn/ConnTests/TerminalLayoutTests.swift`：SwiftTerm iOS Host 手势与普通 scrollback 回归。
- `Conn/ConnUITests/TerminalTmuxWindowNavigationUITests.swift`：tmux UI 滚动冒烟与进程稳定性。
- `Conn/Conn/Me/OpenSourceLicensesView.swift`、`Conn/ConnTests/AppWideUIConsistencyTests.swift`：版本展示和 vendor 固定断言。

### Task 1: 用失败测试固定滚动签名语义

**Files:**
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalInteractionTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalInteractionControllerTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteractionController.swift`

- [ ] **Step 1: 添加失败测试**

测试必须覆盖：仅 Host revision、persistent revision、Bracketed Paste、Focus Reporting、Synchronized Output 或 Application Cursor 变化时 token 仍匹配；Mouse Tracking、Alternate Buffer、1007、尺寸、freshness、目标 Pane、attachment、mode capability、历史可用性或终端代次变化时 token 失效。

- [ ] **Step 2: 验证 RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter TerminalInteraction
```

Expected: FAIL，现有 token 仍严格比较 `protocolRevision` / `persistentRevision`，且尚无 1007 路由字段。

- [ ] **Step 3: 实现最小滚动签名**

增加 `TerminalHostScrollSignature` 与 `TerminalPersistentScrollSignature`；`TerminalRouteToken` 保存终端代次、attachment 代次和这两个签名，不保存原始 revision。`TerminalProtocolState` 增加 `alternateScrollEnabled`，Router 在普通 Alternate Buffer 中仅于 1007 开启时返回 `.plainAlternateKeys`。

- [ ] **Step 4: 验证 GREEN**

Run: `swift test --package-path Packages/ConnPackages --filter TerminalInteraction`

Expected: PASS。

### Task 2: 用失败测试固定 tmux 异步请求边界

**Files:**
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxInteractionTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxControlHubTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/PersistentTerminalInteractionTests.swift`
- Modify: `Packages/ConnPackages/Tests/ConnMultiplexerTests/TmuxProviderControlRuntimeRegistryTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/PersistentTerminalInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxInteraction.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxProviderControlRuntimeRegistry.swift`
- Modify: `Packages/ConnPackages/Sources/ConnMultiplexer/TmuxControlHub.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Conn/Conn/Terminal/TerminalTmuxQuickActionSmokeSupport.swift`

- [ ] **Step 1: 添加历史读取和 Copy Mode 失败测试**

历史读取测试允许请求创建后发生无关 snapshot revision 漂移，并拒绝 Pane/attachment 变化。Hub 测试让 mode scroll 在队列等待期间发生无关 revision 漂移，预期仍执行；让 freshness、Pane、attachment 或 mode capability 改变，预期拒绝且不 dispatch 命令。

- [ ] **Step 2: 验证 RED**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter 'TmuxInteraction|TmuxControlHub'
```

Expected: FAIL，现有请求和 Hub 仍比较 `expectedStateRevision`。

- [ ] **Step 3: 移除错误的全局 revision 前置条件**

从 `PersistentTerminalHistoryRequest` 和 `PersistentTerminalModeScrollRequest` 删除 `expectedStateRevision`。同步更新两个请求的所有生产构造点、协议测试、registry 测试和 UI smoke backend；`PersistentTerminalQuickActionRequest.expectedStateRevision` 保持不变。历史 backend 校验 target/attachment，结果记录 pinned 最新 revision；Hub 获取串行执行槽后从当前 snapshot 解析 attachment 的当前 Pane，要求 target 一致、freshness 非 stale 且 capability 为 `.scrollable` 后才 dispatch。

- [ ] **Step 4: 验证 GREEN**

Run: `swift test --package-path Packages/ConnPackages --filter 'TmuxInteraction|TmuxControlHub'`

Expected: PASS。

### Task 3: 升级 SwiftTerm vendor 到 v1.19.0

**Files:**
- Replace: `Packages/Vendor/SwiftTerm/`（官方 v1.19.0 tracked tree）
- Modify: `Packages/Vendor/SwiftTerm/Package.swift`
- Create: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/SwiftTermBuildInfo.swift`
- Modify: `Packages/Vendor/SwiftTerm/CONN_UPSTREAM.md`
- Port: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/TerminalHostInteraction.swift`
- Port: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/Terminal.swift`
- Port: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/EscapeSequenceParser.swift`
- Port: `Packages/Vendor/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`
- Port: `Packages/Vendor/SwiftTerm/Tests/SwiftTermTests/TerminalHostInteractionTests.swift`

- [ ] **Step 1: 验证来源并重建官方 v1.19.0 基线**

先执行 `git -C <upstream> rev-parse v1.19.0^{commit}` 并要求精确等于 `464df5207fc2432e16c9a23abe538187196daf5f`，再从该 detached worktree 用 `rsync -a --delete --exclude=.git --exclude=.build <v119>/ Packages/Vendor/SwiftTerm/` 重建官方 tracked tree。必须同步上游 tracked `.swiftpm/xcode/xcshareddata/xcbaselines`；只排除非源码的 `.git` 和构建缓存 `.build`。此步骤只建立待适配的第三方基线，不宣称 Conn 已可用。

- [ ] **Step 2: 在新基线上添加 vendor 版本和 1007 Host 状态失败测试**

更新 v1.19 真实存在的 `Tests/SwiftTermTests/SwiftTermBuildInfoTests.swift`，断言静态 BuildInfo 完整 API：`branch == nil`、`tag == "v1.19.0"`、`commit == "464df5207fc2432e16c9a23abe538187196daf5f"`、`hasUncommittedChanges == false`、`version == "v1.19.0"`；在移植的 Conn Host interaction tests 中要求 Terminal 收到 DECSET/DECRST 1007 和 RIS 时 Host 状态同步变化。

- [ ] **Step 3: 验证 RED**

Run: `swift test --package-path Packages/Vendor/SwiftTerm --filter 'SwiftTermBuildInfo|TerminalHostInteraction'`

Expected: FAIL；上游 BuildInfo 插件会读到 Conn 父仓库信息，且 v1.19 尚未包含 Conn Host 状态与 1007 桥接。

- [ ] **Step 4: 静态化 BuildInfo 并移植 Conn vendor 补丁**

从 `Package.swift` 删除 `SwiftTermBuildInfoPlugin` 挂载、`SwiftTermBuildInfoGenerator` executable target 和 plugin target；删除不再引用的 `Plugins/SwiftTermBuildInfoPlugin`、`Sources/SwiftTermBuildInfoGenerator`，在 SwiftTerm source target 内增加静态 `SwiftTermBuildInfo.swift`。逐项移植 Conn 补丁，不覆盖 v1.19 对 parser、selection、scroll repaint、IME、OSC 133、BiDi 和 Alternate Scroll 的实现。

- [ ] **Step 5: 验证 SwiftTerm 测试集**

Run: `swift test --package-path Packages/Vendor/SwiftTerm`

Expected: PASS。

### Task 4: 将历史任务绑定完整路由签名

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalHostingView.swift`
- Modify: `Packages/ConnPackages/Sources/ConnTerminal/TerminalInteraction.swift`
- Modify: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalInteractionControllerTests.swift`
- Create: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalHistoryPublicationPolicyTests.swift`
- Modify: `Conn/ConnTests/TerminalLayoutTests.swift`

- [ ] **Step 1: 添加失败测试**

从 UIKit Coordinator 提取纯 Swift `TerminalHistoryPublicationPolicy`，增加可在 host 与 simulator 复用的失败测试：无关 revision 更新后仍允许发布；freshness 变 stale、historyAvailable 消失、进入 Copy Mode、Alternate Buffer、Mouse Tracking、1007 关闭、Pane/attachment/尺寸/终端代次变化后拒绝发布。

- [ ] **Step 2: 验证 RED**

Run: `swift test --package-path Packages/ConnPackages --filter ConnTerminalTests`

Expected: FAIL，现有 history task 仅比较 target 和 attachment。

- [ ] **Step 3: 实现签名绑定与发布前 Router 复核**

启动 capture 时记录 `TerminalRouteToken`；`updateInteractionContext()` 通过纯逻辑 policy 在签名不匹配时取消 capture；完成时要求 token 仍匹配且 Router 最新结果为同一目标的 `.providerHistory`。状态解析完成后仅重放同代次 accumulator 行数。

- [ ] **Step 4: 验证 GREEN 与 UIKit 回归**

Run:

```bash
swift test --package-path Packages/ConnPackages --filter ConnTerminalTests
```

Expected: PASS。

### Task 5: 更新版本元数据与自动化 UI 验收

**Files:**
- Modify: `Conn/Conn/Me/OpenSourceLicensesView.swift`
- Modify: `Conn/ConnTests/AppWideUIConsistencyTests.swift`
- Modify: `Conn/ConnUITests/TerminalTmuxWindowNavigationUITests.swift`
- Modify as needed: `Conn/Conn/Terminal/TerminalTmuxQuickActionSmokeSupport.swift`

- [ ] **Step 1: 更新版本断言并添加 UI 回归**

开源许可显示 SwiftTerm 1.19.0。UI smoke 的持久 provider 产生可滚动历史，并在手势期间发布无关 revision；XCUITest 连续 swipeUp/swipeDown，断言 Review/滚动结果出现、无错误 Toast、App 保持前台。随后通过 smoke 状态切换覆盖 Copy Mode、Alternate Buffer/1007，并确认长按选择、方向盘和快捷键栏仍可操作。

- [ ] **Step 2: 发现当前唯一已启动模拟器**

Run（直接访问本机 CoreSimulator，不在隔离沙箱内先试）: `xcrun simctl list devices booted -j`

Expected: 精确获得一个当前已启动设备 UDID；不创建、不 clone、不重启模拟器。

- [ ] **Step 3: 在该 UDID 运行相关单测**

Run（全部直接访问本机 CoreSimulator）:

```bash
xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'platform=iOS Simulator,id=<BOOTED_UDID>' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnTests/AppWideUIConsistencyTests

xcodebuild test -project Conn/Conn.xcodeproj -scheme ConnTerminal \
  -destination 'platform=iOS Simulator,id=<BOOTED_UDID>' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1

xcodebuild test -project Conn/Conn.xcodeproj -scheme ConnMultiplexer \
  -destination 'platform=iOS Simulator,id=<BOOTED_UDID>' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1

xcodebuild test -project Conn/Conn.xcodeproj -scheme SwiftTerm \
  -destination 'platform=iOS Simulator,id=<BOOTED_UDID>' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1
```

Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 4: 在同一 UDID 运行 tmux UI 测试**

Run（直接访问本机 CoreSimulator）:

```bash
xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'platform=iOS Simulator,id=<BOOTED_UDID>' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnUITests/TerminalTmuxWindowNavigationUITests
```

Expected: `** TEST SUCCEEDED **`，普通滚动、tmux 滚动、Copy Mode、Alternate Buffer/1007、选择、方向盘、快捷键栏、Window 横滑和进程稳定性均通过。

### Task 6: 全量复核与交付

**Files:**
- Review: all changed files

- [ ] **Step 1: 检查工作区与差异边界**

Run: `git status --short && git diff --check && git diff --stat`

Expected: SSH 10 秒超时两处既有修改保持，SwiftTerm/tmux 变更仅覆盖计划文件。

- [ ] **Step 2: 运行全量相关 Package 测试**

Run:

```bash
swift test --package-path Packages/Vendor/SwiftTerm
swift test --package-path Packages/ConnPackages
```

Expected: PASS。

- [ ] **Step 3: 重新阅读设计与计划逐项核对**

确认 vendor commit、静态 BuildInfo、1007、普通 scrollback、tmux history、Copy Mode、历史发布保护和模拟器测试证据完整，不把当前 SSH 超时修改误归入本次实现。
