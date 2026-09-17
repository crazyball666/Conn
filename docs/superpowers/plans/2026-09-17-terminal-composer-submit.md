# 终端草稿多行发送与键盘提交 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复多行草稿无法发送，收起时键盘发送整段草稿并追加回车，展开时保留编辑换行。

**Architecture:** 复用现有 UITextView、Composer 状态和 SwiftTerm 粘贴编码，明确区分仅填入与发送并执行。纸飞机在未启用 bracketed paste 的多行场景增加风险确认；确认期间保留草稿与原 target，取消或失效不发送。SwiftTerm 粘贴字节与执行回车合并一次入队，不新增 SSH 或 provider 通道。

**Tech Stack:** Swift / SwiftUI / UIKit / SwiftTerm / Swift Testing / XCTest。

---

用户已明确要求直接实现；在当前工作区保留已有改动，不新建 worktree、不提交或 push。此次不改尺寸、间距、录音焦点与数据库。

## 行为约定

- 收起：系统 `.send` Return 提交整段草稿，编码完粘贴之后追加一个 `CR`；不把回车留在草稿中。
- 展开：系统默认 Return，只增加换行；完成只收起，纸飞机只填入。
- 粘贴多行、中文候选确认和语音转写不能被误判为键盘提交。
- 安全的仅填入沿用 bracketed paste；远端未启用时，明确警告裸换行可能逐行执行，用户选择“仍然发送”才继续，不静默改变原文或强行添加括号粘贴协议。
- 系统键盘样式由 UIKit/输入法控制，不通过私有 API 强制覆盖按键图标。

## Task 1：回归测试先行

Files: `Packages/ConnPackages/Tests/ConnTerminalTests/TerminalCommandComposerTests.swift`、`Conn/ConnTests/TerminalComposerAppearanceTests.swift`。

- [x] 新增收起 Return 不增加换行、展开 Return 保留原文、执行意图允许多行的测试。
- [x] 包测试已复现旧策略的 6 个断言失败；App 行为测试受设备未启动限制，尚未运行。

## Task 2：最小修复与安全确认

Files: `Packages/ConnPackages/Sources/ConnTerminal/TerminalCommandComposer.swift`、`TerminalComposerTextInput.swift`、`TerminalHostingView.swift`、`TerminalComposerExpandedEditor.swift`；`Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`。

- [x] 分离 insert/execute，紧凑输入 Return 回调，避免 IME/粘贴误发送，保留焦点和只读状态。
- [x] 用原生警告承接不安全多行插入，冻结待确认草稿并校验原目标；取消/宿主退出解锁并保留草稿。
- [x] SwiftTerm 编码与追加回车作为一次队列请求登记；失败保留草稿。
- [x] 新文案补齐五种语言，不覆盖现有 catalog 修改。

## Task 3：验收与评审

Files: `Conn/ConnUITests/ConnUITests.swift`；现有 composer 设计文档和本次验收记录。

- [x] 包测试：`swift test --package-path Packages/ConnPackages --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalPasteTests'`，24 项通过。
- [x] `xcodebuild build-for-testing -quiet -project Conn/Conn.xcodeproj -scheme Conn -destination 'generic/platform=iOS Simulator' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1` 编译通过，不代表运行测试通过。
- [ ] App 测试：`xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:ConnTests/TerminalComposerAppearanceTests -only-testing:ConnTests/LocalizationCoverageTests`。
- [ ] 同台设备 XCUITest：`-only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend`；多行输入改在全屏编辑，实际点击紧凑键盘发送，保留布局/键盘回归。
- [ ] 设备当前未启动，等待用户启动后运行，不自行改变设备生命周期；若始终不可用，如实记录未验收。
- [x] 定向评审、`git diff --check`、更新需求及实际测试证据，不报告未通过的测试为成功。全量包测试因 signal 10 中止，已补跑相关 suite。
