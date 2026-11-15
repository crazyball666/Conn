# 终端连接弹窗修复与验收

日期：2026-11-15。

## 范围与根因

本次沿用 2026-11-12 的即时进入终端与阶段卡片方案，不修改连接方式、provider 协议、数据库或订阅配置。保留开始时已有的 ServersView、TerminalScreen、TerminalConnectionOverlay、TerminalHostingView、AppWideUIConsistencyTests 改动及三张未跟踪图片。

1. 私有网络复用 runtime 只发出 `route_setup`，不重复发出配置、凭据和节点准备样本。进度中心只完成收到事件的单个节点，留下前置 active/pending，再激活后续节点，造成多个活动状态。迟到样本也能改写失败/取消/成功结果，`cancelled` 被成功分支处理。
2. SwiftUI 的单行节点仍插入透明的空副标题；固定 44pt 行高限制 Dynamic Type。全局时间轴 overlay 画在图标之上；九阶段列表固定 242pt 且不跟随活动节点，重要状态可能在裁切区域之外。
3. 成功卡片仍在停留时已解除输入抑制。UIKit 的窗口挂载自动获焦回调和 SwiftUI 的 onAppear/onChange 不处于同一个时序边界，导致遮罩下自动获焦。
4. 延迟收键盘任务捕获旧的 `isInputSuppressed`，取消 sleep 后仍继续执行；完成后用户主动打开键盘也可能被旧任务收起。命令输入框同样有重新挂载时的焦点入口。
5. 以当前时间在 View 计算中判断成功停留没有可靠的到期更新来源；tab 与 activity 的完成时序也不同，需要由实际观察到的连接活动驱动完成退场。

## 修复约束

- 进度单向推进，同一活动只有一个进行中节点；未测量的耗时不伪造为 0.0s。最终成功由协调器确认，终态拒绝迟到变更。
- 弹窗显示期间从原生输入边界阻止自动获焦，并屏蔽底层交互；解除后不主动打开软键盘。
- 内容足够时卡片居中，超过六个阶段时阶段列表独立滚动，高度为 242 pt。小屏或大字号放不下卡片时改为正文统一滚动，操作区保持可达。单行文字与节点垂直居中，连接线在图标后方。
- 保留原有流光描边，连接及重连中转动，开启减弱动态效果或连接结束时停止转动。节点切换和完成退场沿用 Conn 动效。

## 验证记录

使用已启动的 iPhone 17 Pro 模拟器，iOS 26.0，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1`。未创建、克隆、启动、重启、抹掉、关闭或切换设备。

- 修复前包测试：`swift test --package-path Packages/ConnPackages --filter TerminalConnectionProgressTests`，6 个测试方法（含 3 个终态参数用例），8 个断言失败，复现路由复用、多活动节点、取消、迟到变更、过早成功。日志 `/tmp/conn-progress-red.log`。
- 修复前 App 测试：`AppWideUIConsistencyTests` + `TerminalLayoutTests`，103 通过、4 失败。其中本次新增弹窗规则和 UIKit 挂载焦点回归失败；另有两项既有源码断言失败：`terminalScreenUsesThemeAppearance`、`terminalFileBrowserUsesDirectSheet`，未扩展修改对应功能。结果 `/tmp/conn-overlay-red-suites.xcresult`。
- 首次用不带 `()` 的 Swift Testing 单方法过滤执行了 0 项测试，`/tmp/conn-overlay-red.xcresult`，不作为通过或回归证据；随后改跑完整 suite 得到上述结果。

## 修复后验证

### 包测试

```bash
swift test --package-path Packages/ConnPackages --filter 'TerminalSessionCoordinatorTests|TerminalConnectionProgressTests'
swift test --package-path Packages/ConnPackages
```

- 恢复提交修复后定向 54 项通过，包含恢复准备过程中记录失效时关闭 attachment/channel、取消活动，以及普通恢复成功。日志 `/tmp/conn-progress-restore-green.log`。恢复流程此前在校验记录和提交 Tab 之前就标记成功，本次将带 `progressActivityID` 的完成权留给外层提交逻辑。
- 全量最近一次执行 1127 项，1124 通过、3 失败，不能称为全量通过。日志 `/tmp/conn-overlay-packages-final.log`。失败均在未修改的语言断言：`BuiltinSnippetsTests` 两项要求中文分组，`DockerComposeTests` 一项要求中文错误；host 环境实际返回英文。没有跳过或删除这些断言。
- 最后复查补齐 SSH 内部自动重试边界：Citadel 会对同一活动发送每次握手失败样本，首个可重试失败不能锁定整次连接。`ConnectionPhaseSample.isFinalFailure` 默认 true，仅私有网络仍有重试机会的瞬时错误标记为 false；保留逐次分析事件和原始错误日志，不改重试策略或分析属性。新增两项回归先得到 8 个失败断言，再通过。最终命令 `swift test --package-path Packages/ConnPackages --filter 'TerminalSessionCoordinatorTests|TerminalConnectionProgressTests|ConnectionRetryPolicyTests'`，59 项通过，日志 `/tmp/conn-progress-retry-green.log`。此次补充后没有重复全量包测试，以上 1127 项结果早于最后两项用例。

### 默认配置的设备定向验收

```bash
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -collect-test-diagnostics never \
  -only-testing:ConnTests/TerminalConnectionOverlayTests \
  -only-testing:ConnTests/TerminalConnectionPresentationTests \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnTests/KeyboardDismisserTests \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalScreenShowsConnectionProgressOverlay()' \
  -only-testing:ConnUITests/ConnUITests/testTerminalOpensImmediatelyAndShowsConnectionStages \
  -only-testing:ConnUITests/ConnUITests/testTerminalCenterOpensWithoutCrashing \
  -resultBundlePath /tmp/conn-overlay-final.xcresult
```

- exit 0；结果包确认 62 通过、0 失败、1 跳过：61 项 App 逻辑/原生输入/渲染测试通过，终端入口 XCUITest 通过，完整弹窗 XCUITest 因当前主机数量达到订阅上限而跳过。跳过不计作交互验收通过。
- 新增布局用例实际挂载生产视图，覆盖 320×568 直连、393×744 九阶段流程、320×568 accessibility3 失败状态，验证滚动内容、操作区空间和失败节点可见，保存并人工检查深/浅色截图。没有改变系统字号或主题设置。
- 新增 SwiftTerm 挂载回调与原生 Composer 禁用/解除测试通过；成功停留的两种更新顺序、已连接会话重新打开、旧计时与重试活动隔离三项通过。取消旧任务后不再有延迟的全局收键盘循环。
- 三项已有 Composer IME/录音/焦点移交测试仍记录 SwiftUI 状态更新警告，断言通过。这些直接挂载的编辑器保持启用，不经过本次禁用路径；没有在本轮扩大修改。新增禁用测试的同类警告已通过按最新状态延迟释放 responder 解决，最终复跑未再出现。

### 中间运行与环境异常

- 新测试夹具初次编译分别遇到只读 `accessibilityReduceMotion` 环境值、缺少显式 Combine import，均已修正后重跑，不算产品回归或通过证据。
- `/tmp/conn-overlay-render-composer-red.xcresult` 的 staging 日志先复现 Composer 的三个焦点断言失败，随后测试宿主发生 SIGABRT：`SnippetsViewModel.__deallocating_deinit` → Swift `TaskLocal::StopLookupScope` → 非法释放。保留对应日志及系统 crash report；未修改无关 Snippets 功能。
- 渲染夹具改为非 key window 后定向测试均执行通过；`/tmp/conn-overlay-green.xcresult` 的 staging 记录 61 项通过，但 Xcode 卡在 `collectSimulatorDiagnostics`。对本次测试进程采样确认后终止阻塞的 xcodebuild；这些未完整结束的运行不替代最终结果。
- 随后使用 Xcode 官方 `-collect-test-diagnostics never` 关闭额外 sysdiagnose 收集，仍保留 xcresult、测试断言、日志和截图，得到上述完整默认配置结果。未重启模拟器或系统服务。

### 完整点击用例的补充尝试

为避免默认主机额度阻塞，临时按项目说明取消 `Conn/Config/Conn.xcconfig` 的免订阅标记注释，执行 `xcodebuild clean`，然后使用同台设备、相同串行与诊断参数，仅指定：

```text
-only-testing:ConnUITests/ConnUITests/testTerminalOpensImmediatelyAndShowsConnectionStages
```

- `/tmp/conn-overlay-ui.xcresult`：1 项失败，前置主机页已出现，但 TabBar 没有暴露 `tab.servers` identifier。测试改用已存在的语义按钮 `servers.add` 等待页面。
- `/tmp/conn-overlay-ui2.xcresult`：1 项失败，点击 `servers.add-host` 后菜单仍在，主机表单没有出现；尚未进入连接页，未创建临时主机。未扩大修改主机菜单或使用坐标点击、修改既有主机来绕过前置问题。完整日志展开/重试/取消/前后台 UI 用例仍未验收通过。
- 免订阅构建已结束，`Conn.xcconfig` 已恢复原始注释状态，没有保留配置 diff。没有创建或删除既有主机。

### 恢复默认配置后的最终设备运行

```bash
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -collect-test-diagnostics never \
  -only-testing:ConnTests/TerminalConnectionOverlayTests \
  -only-testing:ConnTests/TerminalConnectionPresentationTests \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalScreenShowsConnectionProgressOverlay()' \
  -resultBundlePath /tmp/conn-overlay-restored.xcresult
```

最终代码（含内部自动重试补充）编译后执行 47 项，46 通过、1 失败、0 跳过，exit 65。失败为已有 `testCompactAccessoryAndSpeechStates` 的宿主崩溃，结果包报告 `Crash: Conn at +[XCTWaiter _synchronouslyWaitForTimeInterval:]`，不是本次新增断言失败；同一轮其余 46 项，包括本次全部新增 App 回归均通过。不能把这一整轮称为通过。未重启设备或修改无关代码继续绕过崩溃。日志 `/tmp/conn-overlay-restored.log`。

最终 `git diff --check` 通过；保留原有改动，无提交、push 或 PR。实际生产组件截图见 `/tmp/conn-overlay-final-attachments/`（使用测试主机内容，包含于默认配置的成功结果包）。

## 验收边界

- 本次不代表真机或真实 Linux/macOS/tmux/zellij 远端验收通过。provider 与恢复/取消路径由 fixture/包测试覆盖；没有在生产代码植入测试账号或隐藏入口。
- 默认配置整组 App 全量测试未运行；基线源码 suite 的两项既有失败保留。最终定向源码检查已执行通过。
- 无新增本地化键；可见文案与辅助功能状态复用现有五语言 `L()` 文案，SSH/PTY/远端原始错误保持原文。

## 流光、列表限高与崩溃修正

恢复原来的流光和多阶段列表 242 pt 上限，保留节点垂直对齐、活动节点自动滚动及小屏兜底。三份宿主崩溃报告均指向 `SnippetsViewModel` 隐式析构进入 Swift 并发运行时的 `TaskLocal::StopLookupScope` 后非法释放。显式 `nonisolated deinit {}` 避开该调用，模型其余成员仍受 `@MainActor` 隔离。对应 [Swift issue #88036](https://github.com/swiftlang/swift/issues/88036)。

同一 iPhone 17 Pro 模拟器（iOS 26.0，`DDACC334-4130-4FA3-AC0A-A28B62F71FC1`）上，修前测试复现九阶段列表无独立滚动和同步任务作用域释放模型时非法释放，结果见 `/tmp/conn-overlay-restore-red-v2.xcresult`。修后执行如下命令，15 项通过，包含上次崩溃的输入栏用例。用户自行验收界面点击与真实连接。

```bash
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -collect-test-diagnostics never \
  -only-testing:ConnTests/TerminalConnectionOverlayTests \
  -only-testing:ConnTests/SnippetsViewModelLifetimeTests \
  -only-testing:ConnTests/SnippetsViewModelTests \
  -only-testing:ConnTests/TerminalComposerAppearanceTests/testCompactAccessoryAndSpeechStates \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalScreenShowsConnectionProgressOverlay()' \
  -resultBundlePath /tmp/conn-overlay-restore-green-v2.xcresult
```
