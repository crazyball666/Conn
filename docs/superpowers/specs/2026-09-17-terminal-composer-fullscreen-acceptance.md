# 终端单行 / 全屏编辑验收

## 改动

- 底栏采用原生单行输入视口，原文换行不丢失。默认输入框高度 36pt；按最后追加要求，上边距从 4pt 增加至 8pt，下方快捷键距离保持不变，底栏共 90pt。录音、停止和长草稿不增高。
- 全屏按钮位于输入胶囊内、发送按钮左侧，两个按钮同为 26pt；右侧语音按钮 36pt。按用户明确要求，按钮热区与可见边界相同，不再外扩到 44pt；两行视觉距离相应减少约 4pt。
- 全屏编辑器与底栏绑定同一份草稿，完成只返回底栏并恢复焦点。发送复用原来的目标校验、bracketed paste 和失败保留逻辑，不追加回车、不自动执行。
- 全屏采用原位覆盖，不卸载终端视图，不触发终端 detach。底下的终端在编辑期间保留，禁用其点击与辅助功能访问。
- 录音时旧代码会显式取消焦点并 disabled 输入框，已用失败测试确认。现在通过原生 delegate 阻止手动修改，保持同一 first responder；未打开键盘时也不会因为开始录音而主动打开。
- 新文案在 ConnUI 字符串目录补齐五种语言；保留工作区原有 App 字符串目录修改。

## 设备与命令

iPhone 17 Pro 模拟器 / iOS 26.0，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1`。未创建 Clone、重置或切换验收设备。

```bash
swift test --package-path Packages/ConnPackages --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalTextInsertion|TerminalSpeech'
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnTests/LocalizationCoverageTests \
  '-only-testing:ConnTests/AppWideUIConsistencyTests/terminalTouchGlowBelongsToWholeInputBar()' \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend \
  -resultBundlePath /tmp/conn-fullscreen-green-2.xcresult

# 最新上边距修订的组件与真实页面复验
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend \
  -resultBundlePath /tmp/conn-composer-top-inset-verified.xcresult
git diff --check
```

## 验证记录

- RED：`/tmp/conn-fullscreen-focus-red.xcresult` 确认旧实现进入 listening 后失去第一响应者；`/tmp/conn-fullscreen-red-2.xcresult` 确认旧布局 44pt 热区 / 94pt 底栏不符合新尺寸。
- 定向包测试：22 项、3 个 suite 通过。
- 首轮生产组件测试：`/tmp/conn-fullscreen-green-1.xcresult`，5 项通过，0 失败、0 跳过；覆盖固定高度、深浅色、Dynamic Type、触摸光效、录音状态切换焦点。
- 增强回归发现最初尝试的 UITextField 会规范化换行，已替换为共享 UITextView 的单行高度视口；`green-2` 的 30 通过 / 2 失败不计作最终通过。只读 review 提出的 IME 同步风险也在 `ime-red` 中复现：组词会阻止转写显示与草稿清空。现在仅在录音或外部草稿更新时结束组词，并抑制旧组合回写，不取消焦点。
- 修正后的 `green-3`：9 项组件测试通过，0 失败、0 跳过；覆盖 Unicode、CRLF、Return 保留、紧凑及全屏焦点、组词与程序更新、深浅色、大字号及跨行光效。再次只读复查未发现明确实质性缺陷。
- `final` 的 32 项 App 测试通过，UI 测试仍失败，不计作完整通过。覆盖布局 18、本地化 4、光效归属 1、编辑器 9。后续 `ui-verified` 的 9 项组件测试也通过；UI 所有草稿、焦点续写、尺寸、选择、键盘和展开操作断言通过，但仍失败于底层节点不存在的检查。
- 全屏底层必须保持挂载。XCTest 仍能解析其隐藏节点，`opacity(0)` 与显式忽略辅助功能子节点均不改变此查询结果，不能据 `exists` 判断可见或可点击。移除无效的透明度处理，保留 `accessibilityHidden`、忽略子节点及禁用触控；UI 测试改为验证底层控件 `isHittable == false`，不把节点查询当作真实 VoiceOver 导航验收。
- 同轮键盘断言区分了系统行为：iOS 26 的 AX 键盘框不含圆角顶边，截图证实底栏贴合，断言改为禁止重叠及额外一行间距；模拟器硬件键盘模式下 XCTest 的软件键盘覆盖按输入客户端生效，返回后通过不额外点击的 `x + delete` 验证可续写并恢复测试键盘，不改生产焦点逻辑。
- 增强 XCUITest 最终通过：`/tmp/conn-fullscreen-interaction-verified.xcresult`，1 项通过、0 失败、0 跳过，已确认全屏往返、多行原文、未点击发送不清空、发送后续写、隐藏底层触控、选词替换、键盘开关与快捷栏展开/收起。连同 32 项 App 测试及 22 项包测试，覆盖 55 个不同定向测试方法。
- 上述流程通过后，用户追加增大输入框上边距。`/tmp/conn-composer-top-inset-red.xcresult` 先确认旧高度 86pt 不满足新 90pt 规格；改为顶部 8pt 后，`/tmp/conn-composer-top-inset-verified.xcresult` 的 9 项组件 + 1 项完整 UI 流程全部通过，0 失败、0 跳过。已查看最终单行、键盘与全屏截图；底部两行距离、36pt 输入框与 26pt 内置按钮尺寸不变。
- 最终 `git diff --check` 通过。工作区原有 App 字符串修改未覆盖；未产生工程配置或构建产物改动，未提交或 push。

## 限制

- 录音状态由生产组件夹具注入，不能替代真实麦克风、系统首次授权和转写服务的真机验收；本次不更改语音服务实现。
- 未实测真实 VoiceOver 导航；自动化仅验证语义控件及全屏覆盖期间的触控隔离，不声称完整辅助功能审计通过。
- 真实 App 点击测试使用当前模拟器已存主机的普通 PTY；未额外执行 tmux/zellij 真实远端测试。
- 未执行全量包、App 或 UI suite，不将定向结果描述为全量通过。
- 不提交、不 push；所有本次和原有工作区改动保留。

## 2026-09-17：展开态发送按钮尺寸修正

- 根因：全屏独立按钮复用了紧凑胶囊内的 26pt 发送样式，语音按钮则是 36pt。
- 展开态改为 36pt 圆形、16pt 图标，与语音按钮相同，按 `.callout` 同步缩放；紧凑态保持 26pt / 14pt。不外扩热区，不改发送或键盘焦点逻辑，不新增文案。
- 实际设备：用户已启动的 iPhone 17 Pro Simulator，iOS 26.0，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1`；未启动、重启、克隆或切换设备。

本轮命令：

```bash
xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -only-testing:ConnTests/KeyboardDismisserTests \
  -only-testing:ConnUITests/ConnUITests/testExpandedComposerSendMatchesVoiceButton \
  -resultBundlePath /tmp/conn-expanded-send.7kswWV/green.xcresult
swift test --package-path Packages/ConnPackages --filter TerminalCommandComposerTests
git diff --check
```

- RED：同一 Xcode 设备参数，仅选择 `testExpandedComposerSendMatchesVoiceButton`，结果 `/tmp/conn-expanded-send.7kswWV/red.xcresult`。真实点击展开后，尺寸断言复现 `26.0 != 36.0`。
- 修复后新增 UI 测试通过，未跳过；覆盖展开按钮等宽/等高/中心对齐、空草稿禁用、有内容启用、完成后保留草稿与紧凑发送仍为 26pt。仅编辑草稿，没有向远端执行命令。
- 新增 App 组件尺寸测试通过，覆盖默认与辅助字号、启用/禁用状态；包测试 12 项通过。
- 已实际查看从 UI 测试导出的截图：`/tmp/conn-expanded-send.7kswWV/attachments/D0BD02CF-458E-4272-8660-32C4694A8C6C.png`，两按钮同尺寸、居中，未修改原有底栏间距。
- 扩展回归整体为 **34 通过、1 失败、0 跳过，exit 65**，不能称为整组通过。失败为原有 `testProductionEditorsRoundTripWithoutKeyboardHide`，iOS 26 下观测到一次键盘隐藏通知。
- 在相同设备参数下单独选择尺寸与该焦点测试复跑，`/tmp/conn-expanded-send.7kswWV/focus-recheck.xcresult` 为 1 通过、1 失败：尺寸继续通过，焦点断言继续失败。该问题尚待定位，本轮没有扩大到键盘逻辑修复，也不据此声称键盘交互已通过 iPhone 17 Pro 验收。
- 未运行全量测试、真实录音或 tmux/zellij 集成；只读复查未发现此次尺寸改动的阻断问题。保留原有本地化改动及用户图片，未提交、未 push。
