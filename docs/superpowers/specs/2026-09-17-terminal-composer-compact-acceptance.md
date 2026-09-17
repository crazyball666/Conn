# 终端输入底栏：固定高度与连续触摸光效验收

> 本文记录第一轮固定高度验收。后续按用户要求取消输入行按钮的外扩热区，并加入单行 / 全屏编辑；最新布局是 90pt 底栏（顶部 8pt 留白）、36pt 胶囊/语音按钮、胶囊内 26pt 全屏/发送按钮。见 `2026-09-17-terminal-composer-fullscreen-acceptance.md`；下文 94pt / 44pt 是第一轮历史记录，不是当前规格。

## 改动与根因

- 原输入框按内容增长，录音又增加一行状态标签。旧版渲染回归测得底栏普通状态 102pt、录音约 115.3pt、六行草稿约 160.3pt，导致终端视口跟着跳动。
- 默认字号下，胶囊和语音按钮统一为 36pt 视觉高度，发送圆按钮为 26pt；按 UI/UX 触控规范保留至少 44pt 点击范围。底栏固定 94pt（不含底部安全区），长文本内部滚动；辅助功能字号同步缩放，但同一字号下各状态等高。
- 录音状态不再插入额外文字行，改为占位提示、描边、停止/收尾图标及 VoiceOver 值。复用原五语言文案，不改变语音服务与提交语义。
- 渲染回归同时检查大字号录音态的文字区域不是空白，不仅验证高度。原始截图像素核对确认原生编辑器文字存在；撤销仅凭截图预览误判而尝试的只读 Text 分支，保持原生编辑器。
- 原光效属于 `TerminalKeybar` 自己的背景，并在该行裁剪。现改为 `TerminalInputBar` 统一绘制与手势跟踪；快捷键栏移除独立不透明底色，光效只在完整底栏的外边界裁剪。
- 发送仍只粘贴原文、不追加回车；多行仍保留换行。没有更改数据库、网络或远端协议。

## 设备与验证

设备：用户指定的 **iPhone 17 Pro 模拟器 / iOS 26.0**，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1`。没有创建 Clone、重置设备或切换到其他模拟器。

- 定向包测试：30 项、4 个 suite 通过。
- 首轮 App + XCUITest：27 项通过，0 失败、0 跳过。其中布局 18、本地化 4、渲染 3、光效归属回归 1、真实 App 点击 1。
- 增强验收（`final-2`）：6 项通过，0 失败、0 跳过。其中 4 项渲染测试覆盖深浅色、空/非空草稿、四种语音状态、窄/宽屏、大字号及光效跨行连续性；另有光效归属回归 1 项和增强后的真实 App 点击 1 项。
- 最终复验（`verified`）：9 项通过，0 失败、0 跳过，包含增加文字可见性断言后的 4 项渲染、光效归属回归 1 项、本地化 4 项。最终生产代码与 `final-2` 点击验收时一致。合计覆盖 28 个不同 App/UI 测试方法。
- 旧实现先通过失败测试确认高度不一致与光效裁剪归属，再改生产代码。失败记录：`/tmp/conn-composer-compact-red.xcresult` 和 `/tmp/conn-composer-glow-red-2.xcresult`。
- 首轮真实 App 截图已检查：六行草稿仅显示当前行 `line six`，底栏不增高；发送后可直接续写，键盘开关和快捷栏展开正常。
- 小范围只读 review 未发现明确阻塞问题；补充原生双击选词替换、框内上下滑动的点击验收，避免仅凭 `simultaneousGesture` 推定原生手势正常。
- 最终 XCUITest 的选词替换断言通过；上下滑动后草稿原文、输入区高度保持不变，键盘开关及展开/收起正常。输入时视口自动跟随当前行；滑动截图仍显示当前行，不据此宣称已验证手动回翻所有历史草稿行。
- 已人工查看真实 App、空录音/已有转写/收尾、大字号及光效截图。渲染夹具改为全高 key window，以真实窗口承载原生输入框，不仅依赖离屏小窗口的预览；光效截图与像素断言验证共享背景接缝连续，外边界无溢出。

## 实际执行命令

```bash
swift test --package-path Packages/ConnPackages --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalTextInsertion|TerminalSpeech|TerminalKeybar|TerminalDirectionPadTests'

xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalTouchGlowBelongsToWholeInputBar()' \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnTests/LocalizationCoverageTests \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend \
  -resultBundlePath /tmp/conn-composer-compact-green.xcresult

xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalTouchGlowBelongsToWholeInputBar()' \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend \
  -resultBundlePath /tmp/conn-composer-compact-final-2.xcresult

xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalTouchGlowBelongsToWholeInputBar()' \
  -only-testing:ConnTests/LocalizationCoverageTests \
  -resultBundlePath /tmp/conn-composer-compact-verified.xcresult

git diff --check
```

## 限制与失败记录

- 未执行全量包、App 或 UI suite；不把定向通过表述为全量通过。
- 真实 App 使用已保存主机的普通 PTY；未额外做 tmux/zellij 真实远端集成验收。
- 录音视觉通过生产组件注入状态渲染，不代表真实麦克风、权限与音频转写验收；本次未更改语音服务。
- 开发中一次 Swift Testing 过滤未带方法括号导致 0 项执行，已修正并确认回归实际执行；新增渲染测试有一次缺少 `try` 的编译失败，已修正。均不计为通过。
- 本次不创建提交或 push。
