# 录音与全屏切换键盘焦点修复

日期：2026-09-17。

## 根因与改动

1. App 的全局空白点击手势没有保护 Composer 按钮。SwiftUI 按钮触点不一定是 UIControl；录音切换不改变当前输入 responder，原有的延迟身份检查仍会允许 `endEditing(true)`。
   - 现按紧凑/全屏输入的精确 identifier 排除全局收键盘，在触摸开始和延迟执行处都检查。
   - 同时保护 Composer/input-bar 按钮祖先；普通表单点击空白收键盘保持不变。终端编辑区使用显式键盘按钮管理收起。
2. 展开时显式递增 dismiss token；完成时先移除全屏、再异步请求紧凑输入焦点，产生键盘先收后开的间隙。
   - 移除展开时的 dismiss 与完成时的无条件 focus token。
   - 每个终端宿主持有弱引用 handoff，通过环境传给两个原生输入。完成时先把第一响应者交回仍挂载的紧凑输入，成功后才移除全屏；若键盘已隐藏则不强制打开。
   - 组合回归进一步确认，底层 `allowsHitTesting(false)` 会提前让紧凑输入失焦。移除此处禁用，由不透明全屏覆盖层接管触摸，保留底层可访问性隐藏。
   - 原先焦点异步请求遇到 `window == nil` 直接丢弃；现在原生输入在 `didMoveToWindow` 后重新核对最新 binding，避免首次展开或反复展开漏掉自动获焦。
3. 修正验收遗漏：UI 测试原本在完成后先 typeText 再查键盘，可能掩盖收起/重开的现象。现在切换后先检查键盘；增加全局手势、键盘隐藏通知及真实录音按钮用例。

不改布局、按钮尺寸/热区、语音引擎、数据库或连接协议。保留工作区原有修改，未提交或 push。

## 设备

- 实际运行：已启动的 iPhone 15 Simulator，iOS 17.2，UDID `10FCD941-B0A4-474B-B459-CB6C4659B49A`。
- iPhone 17 Pro Simulator，iOS 26.0，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1` 当前未启动；未启动、重启、克隆、抹掉或关闭设备。
- 本轮结果不代表 iPhone 17 Pro 或真机验收通过。

## 测试证据

### App 回归

```bash
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=10FCD941-B0A4-474B-B459-CB6C4659B49A' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/KeyboardDismisserTests \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerVoiceButtonsKeepKeyboard \
  -resultBundlePath /tmp/conn-keyboard-focus-release-check.xcresult
```

- 最终 33 项 App 定向回归通过，0 失败；2 项 UI 测试跳过（原因见下），exit 0。含全局手势、焦点移交前后、录音状态保留/不强制打开键盘、只读输入与原有外观/字节提交回归。
- 新增实际 SwiftUI 组合的两轮展开/收起测试，验证全屏确实获焦、移除前同步交回、移除后保持、草稿不变，整个期间 `keyboardWillHideNotification` 为零。另覆盖首次挂载全屏编辑器自动获焦。
- 日志：`/tmp/conn-keyboard-focus-release-check.log`。仅定向 suites，不代表全量 App 测试通过。
- 初轮 30 通过、1 失败：上轮 Return 测试误用 `UITextView.insertText` 模拟键盘代理输入，挂入真实窗口仍不触发 shouldChangeTextIn。已明确区分程序化插入与键盘 delegate gate，修正单测；实际系统键盘仍由 XCUITest 覆盖，未把模拟调用声称为真实按键。

### 反向回归证明

暂时禁用此次 Composer 手势保护和同步焦点移交，运行同台设备的 `KeyboardDismisserTests` 与 `testFullscreenHandsResponderBackBeforeRemovingEditor`：3 个相关测试如预期失败、12 项通过，结果在 `/tmp/conn-keyboard-focus-red.xcresult`。随后恢复修复并得到早期 31 项通过结果；没有保留反向验证代码。

补充组合测试在 `/tmp/conn-keyboard-focus-owner.xcresult` 复现展开阶段隐藏键盘；仅取消底层 hit-testing 禁用后，`/tmp/conn-keyboard-focus-hittest.xcresult` 不再隐藏，但仍有展开未获焦失败。补齐窗口挂载时机后，`/tmp/conn-keyboard-focus-lifecycle.xcresult` 两项通过，最终整组回归也通过。调试时出现过未挂入 UIWindowScene、过早查找未渲染输入框、只等旧输入失焦而未等待新输入获焦的测试夹具问题，已修正，未当作产品根因或成功证据。

### 包测试

```bash
swift test --package-path Packages/ConnPackages \
  --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalPasteTests'
```

最终代码重新执行：24 项通过，日志 `/tmp/conn-keyboard-focus-package-final.log`。本轮未重跑全量包测试；上一轮全量曾因 signal 10 中止，不计作通过。

### UI 点击验收的限制

使用同一 xcodebuild 设备/串行参数实际请求了：

```text
-only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend
-only-testing:ConnUITests/ConnUITests/testTerminalComposerVoiceButtonsKeepKeyboard
```

最终代码重新执行：两项均因 iPhone 15 没有已保存的主机配置而跳过，不是通过。与 App 回归一起保存在 `/tmp/conn-keyboard-focus-release-check.xcresult`（33 通过、2 跳过、0 失败）。没有向生产 App 植入测试账号/隐藏入口，也没有迁移其他设备的主机或凭据。

仍待在有主机配置、离线语音识别可用且已授权的设备上完成实际录音按钮和终端全屏往返点击验收。首次系统权限弹窗本身的键盘行为不在应用控制范围内，不能把权限弹窗跳过当作录音成功。

## 代码复查

- 最终定向评审未发现有证据的阻断问题；异步回调读取最新 binding，移交成功后才卸载，引用为弱引用。全局延迟回调保护与取消无条件 focus token 已落实。
- SwiftUI 环境传递、原生输入实际挂载与焦点回调已由实际生产组件组合往返测试补充，不仅依赖 helper 测试；这仍不替代有主机配置设备上的真实点击验收。
- 每轮 Xcode 构建/测试后检查 git 状态；保留原有本地化改动，无新增可见文案。既有 DockerModelsTests withLock 警告未作无关修复。

## 提交前复核（用户后续明确要求提交并 push）

复用上述 iPhone 15、同一 UDID，不改变设备生命周期。新增检查当前改动涉及的 `AppWideUIConsistencyTests`：

```bash
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=10FCD941-B0A4-474B-B459-CB6C4659B49A' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/KeyboardDismisserTests \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnTests/AppWideUIConsistencyTests \
  -resultBundlePath /tmp/conn-precommit.fRIgJx/app-final.xcresult
```

- 最终 112 通过、2 失败、0 跳过，exit 65，不能称为整组通过。本次键盘专项和更新的输入底栏检查通过。
- 初轮 111 通过、3 失败（`/tmp/conn-precommit.fRIgJx/app.xcresult`）：将光效移至输入底栏后，旧 `terminalScreenUsesOptionalInteractionFacet` 仍在 Keybar 内查找背景和渐变。已把对应四项断言移到 Composer 源文件，没有删除断言，复跑通过。
- 剩余 `compactKeybarUsesIconActionsAndPriorityOrder` 的文件按钮在方向键之前断言，在提交前 `HEAD` 同样为 false，所检查的 `compactActionRail` 与 `HEAD` 完全相同。
- 剩余 `terminalScreenUsesThemeAppearance` 要求没有 `.preferredColorScheme(terminalColorScheme)`，但 `HEAD` 已包含；整个 `TerminalScreen.swift` 与 `HEAD` 完全相同。以上两项既有失败按仓库规则记录，不在提交任务中扩展修改按钮排序和主题。
- 重新运行上述包测试命令：24 项通过，日志 `/tmp/conn-precommit.fRIgJx/packages.log`。本次提交前未重新运行全量包测试或 UI 点击测试；上一轮两项 UI 跳过及 iPhone 17 Pro 未验收的限制仍有效。
- 本地化只暂存终端新增六条五语言文案，内容与已测试的工作文件逐项一致；排除原有 App 本地化改动及包目录的无语义排序/格式变化，工作文件原样保留。
- 暂存区 `git diff --cached --check` 通过，未发现高置信度私钥/token 格式，未包含构建产物；提交任务不创建 PR、不强制推送。
