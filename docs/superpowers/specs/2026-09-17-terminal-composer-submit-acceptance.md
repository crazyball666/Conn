# 终端多行发送与键盘提交：验收状态

日期：2026-09-17。

## 实现内容

- 收起输入框：原生键盘 `.send` 提交完整草稿；SwiftTerm 按远端状态编码粘贴，结束标记后才追加 `CR`，整包一次入队。
- 展开编辑器：Return 仍为换行，完成只收起，纸飞机不追加回车。
- 远端未启用 bracketed paste 的多行纸飞机发送不再永久拒绝：告知裸换行可能逐行执行，用户明确确认后发送；取消保留草稿。
- 未 attach、过期 target、已关闭队列不清空草稿；确认捕获原文、target、inputEpoch，宿主退出会解锁。
- 粘贴/拖放在 UIKit 最终插入回调区分，防止单个换行被当作发送；中文候选阶段不提交。保留现有尺寸、按钮热区、主题和录音焦点。
- 按 UI/UX 检查项保留原生风险确认、只读/防重入与焦点边界；没有采用通用设计建议重做 Conn 的颜色、字体或布局。

## 已执行

1. `swift test --package-path Packages/ConnPackages --filter TerminalCommandComposerTests`
   - RED：补齐调用签名但保留旧策略后，新增多行执行/确认测试出现 6 个预期断言失败。
   - 日志：`/tmp/conn-composer-submit-red-policy.log`。
2. `swift test --package-path Packages/ConnPackages --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalPasteTests'`
   - 最新补跑：24 tests / 3 suites 通过，exit 0。
   - 日志：`/tmp/conn-composer-submit-package-final.log`。
3. `xcodebuild build-for-testing -quiet -project Conn/Conn.xcodeproj -scheme Conn -destination 'generic/platform=iOS Simulator' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`
   - App、App 测试和 UI 测试编译通过，exit 0；这只是编译，不是测试执行。
   - 日志：`/tmp/conn-composer-submit-build-3.log`。
   - 前两次编译分别遇到 SwiftUI 表达式类型检查超时、测试文件缺少 SwiftTerm import，均已修正。日志分别为 `...-build.log`、`...-build-2.log`。
   - 保留原有 `DockerModelsTests.swift:313` 未使用 withLock 结果警告，本次未修改无关测试。
4. `swift test --package-path Packages/ConnPackages`
   - 全量运行中止：`Exited with unexpected signal code 10`，exit 1；没有完整通过结果，不能计作通过。
   - 日志：`/tmp/conn-composer-submit-package-all.log`。之后已补跑上述 24 项定向测试。
5. `git diff --check` 通过；每轮 Xcode 构建后检查工作区，保留原有未提交改动，未提交或 push。

## 设备限制 / 未执行

通过 `xcrun xctrace list devices` 与 `xcrun simctl list devices booted` 发现：

- 用户此前指定的 iPhone 17 Pro Simulator，iOS 26.0，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1` 当前未启动。
- 当前运行的是 iPhone 15 Simulator，iOS 17.2，UDID `10FCD941-B0A4-474B-B459-CB6C4659B49A`，未擅自切换验收设备。
- 已请求用户打开原 iPhone 17 Pro；未自行启动、重启、克隆或抹除任何设备。

因此本轮 **没有执行 App 单元测试或 XCUITest，没有新的键盘/确认框截图验收**。新增 App 测试已编译，包括实际 SwiftTerm 字节与 CR 位置、拒绝旧 target、原生 Return、单个换行粘贴、录音只读与焦点回归；不能把它们写成运行通过。

设备启动后待运行：

```bash
xcodebuild test -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnTests/LocalizationCoverageTests \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend
```

该 UI 测试需要模拟器原有的可连接主机。真机输入法、真实音频、远端 tmux/zellij 会话本轮均未验收；没有新增生产测试账号或隐藏入口。

## 已知语义边界

- `.send` 表示系统发送键；iOS 或输入法决定显示箭头还是文字，未使用私有 API 强制替换按键。[Apple UIReturnKeyType.send](https://developer.apple.com/documentation/uikit/uireturnkeytype/send)
- 远端未启用 bracketed paste 时，不能同时承诺原样多行和绝不执行；风险确认不会伪造这种能力。
- 队列接受只表示本地登记成功，不证明网络写入或远端执行成功。
- 独立代码评审未发现明确阻塞问题，但原生 alert 的取消/确认回调顺序仍须 UI 验收。
