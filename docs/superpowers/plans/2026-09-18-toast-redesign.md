# Conn Toast Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Conn 的全局 Toast 改成紧凑、扁平、可换行的状态卡片，并保留现有行为和兼容性。

**Architecture:** 只调整 ConnUI 的 Toast 表现层与状态图标元数据。`ConnToastCenter`、计时器、调用方和全局修饰器保持不变；`info` 继续作为兼容语义，但不渲染图标。

**Tech Stack:** Swift 5 / SwiftUI / Swift Testing / Swift Package Manager / iOS 17+

---

### Task 1: 用测试锁定状态图标语义

**Files:**
- Modify: `Packages/ConnPackages/Tests/ConnUITests/ConnToastTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnUI/Components/ConnToast.swift`

- [x] **Step 1: 更新失败测试**

将 `systemImageName` 断言改为可选值，并明确要求成功、警告、错误有图标，`info` 为 `nil`。

- [x] **Step 2: 运行定向测试确认旧实现失败**

Run: `swift test --package-path Packages/ConnPackages --filter ConnToastTests`

Expected: 旧实现因 `info` 仍返回 `info.circle.fill` 而失败。

- [x] **Step 3: 实现最小状态元数据改动**

将 `ConnToastStyle.systemImageName` 改为 `String?`，仅 `info` 返回 `nil`；视图只在该值非空时渲染图标。

- [x] **Step 4: 运行定向测试确认通过**

Run: `swift test --package-path Packages/ConnPackages --filter ConnToastTests`

Expected: `ConnToastTests` 全部通过。

### Task 2: 重做 Toast 容器布局与视觉

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnUI/Components/ConnToast.swift`

- [x] **Step 1: 写布局回归断言**

为 Toast 视觉规格增加可测试的公开布局令牌，断言最大宽度 320pt、正文 14pt、圆角 16pt，避免后续回退为全宽/小字号样式。

- [x] **Step 2: 运行测试确认新断言失败**

Run: `swift test --package-path Packages/ConnPackages --filter ConnToastTests`

Expected: 新增规格断言因布局令牌尚未存在而失败。

- [x] **Step 3: 实现紧凑扁平 Toast**

使用 `ConnToastLayout` 令牌，将容器设为最大 320pt，短文案按内容自适应宽度、长文案自然换行，使用 14pt 文本和 16pt continuous 圆角；背景随主题反转并保留轻微透明度及上下渐变，正文颜色同步反转；成功、警告、错误统一使用圆形 SF Symbols，info 保持无图标；保留现有手势、无障碍标识和计时，并将进出场调整为上方进入、向上离场的淡入淡出动画。

- [x] **Step 4: 运行定向测试确认通过**

Run: `swift test --package-path Packages/ConnPackages --filter ConnToastTests`

Expected: `ConnToastTests` 全部通过。

### Task 3: 构建与模拟器验收

**Files:**
- Modify: `Conn/Conn/ConnApp.swift` (DEBUG-only visual acceptance trigger)
- Modify: `Conn/ConnUITests/ConnUITests.swift`

- [x] **Step 1: 检查差异和格式**

Run: `git diff --check`，确认只包含 Toast 源码、Toast 测试和本次设计文档。

- [x] **Step 2: 运行 ConnUI 全量包测试**

Run: `swift test --package-path Packages/ConnPackages --filter ConnUITests`

Expected: 相关测试通过；若被工作区已有改动影响，记录真实失败原因。

- [x] **Step 3: 运行 Toast UI 回归测试**

Run: `xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn -destination "id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:ConnUITests/ConnUITests/testToastUsesCompactMultilineStatusCard`

Expected: Toast 以不超过 320pt 的宽度显示，短文案按内容收缩并居中，长文案发生换行，App 保持前台运行。

- [x] **Step 4: 构建 App 到当前已启动的 iPhone 17 Pro 模拟器**

Run: `xcodebuild build -project Conn/Conn.xcodeproj -scheme Conn -destination "id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1" -parallel-testing-enabled NO`

Expected: 构建成功。

- [x] **Step 5: 安装、启动并截图检查**

使用 `xcrun simctl install`, `xcrun simctl launch` 和 `xcrun simctl io ... screenshot`，检查 Toast 在深色/浅色现有主题下的紧凑宽度、圆角、14pt 字体和多行文案布局；不重启或切换用户设备。
