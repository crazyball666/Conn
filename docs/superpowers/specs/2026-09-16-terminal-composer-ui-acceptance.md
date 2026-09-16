# 终端输入底栏重做：验收记录

## 改动

- 按竞品参考与 UI/UX 设计检查结果，输入胶囊、右侧语音按钮和快捷键共用贴底背景；发送按钮放回胶囊内部，不再作为独立悬浮卡片。
- 语音使用内联状态、停止按钮与收尾进度，移除越界脉冲。语音不可用不影响手动编辑/发送；录音期间禁用无法生效的键盘切换。
- 修复发送清空多行草稿后的焦点丢失；收起后重新打开键盘仍编辑草稿。提交语义仍为粘贴，不追加回车。
- 系统键盘和状态栏跟随终端主题。保留五语言、本机语音服务协议及后续替换引擎的边界。
- 修复系统语音服务停止、空结果、启动错误和过期回调的完成语义，避免 UI 卡在收尾状态。

## 设备与结果

- iPhone 17 Pro 模拟器，iOS 26.0，UDID `DDACC334-4130-4FA3-AC0A-A28B62F71FC1`。用户指定后所有验收均使用该目标，不创建 Clone。
- 定向包测试：30 项、4 个 suite 通过。
- App 布局/本地化/语音会话测试：28 项通过。
- App 设置依赖/主题测试：2 项通过。
- XCUITest：1 项通过、0 跳过；验证多行编辑、发送后清空并直接续写、键盘隐藏/重开、六行内容滚动、底栏与系统输入区域相邻、快捷键展开/收起。
- 渲染测试：3 项通过；深浅色、聆听/收尾/不可用状态、320/700pt 宽度、Dynamic Type 与展开面板。

实际窗口截图已人工查看，键盘与底栏贴合，六行草稿显示最后四行且不出现上方空白。截图只截取底部输入区域，不包含主机信息或远端输出。

## 实际执行命令

```bash
swift test --package-path Packages/ConnPackages --filter 'TerminalCommandComposerTests|TerminalSessionTests|TerminalTextInsertion|TerminalSpeech|TerminalKeybar|TerminalDirectionPadTests'

xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalLayoutTests \
  -only-testing:ConnTests/LocalizationCoverageTests \
  -only-testing:ConnTests/AppleSpeechInputServiceTests \
  -resultBundlePath /tmp/conn-composer-redesign-17pro-final-unit.xcresult

xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalSettingsDependencyTests \
  -only-testing:ConnUITests/ConnUITests/testTerminalComposerKeepsMultilineDraftUntilExplicitSend \
  -resultBundlePath /tmp/conn-composer-redesign-17pro-8.xcresult

xcodebuild test -quiet -project Conn/Conn.xcodeproj -scheme Conn \
  -destination 'platform=iOS Simulator,id=DDACC334-4130-4FA3-AC0A-A28B62F71FC1' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests/TerminalComposerAppearanceTests \
  -resultBundlePath /tmp/conn-composer-redesign-17pro-final-appearance.xcresult

git diff --check
```

## 限制与未通过项目

- `swift test --package-path Packages/ConnPackages` 全量运行因测试进程 `signal 11` 中断，不能认定全量通过；日志为 `/tmp/conn-composer-redesign-package-all.log`。随后补跑上述定向测试并通过。
- 未执行全量 App/XCUITest。开发中的焦点/几何断言失败已保留在第 2–6 轮结果中，第 7、8 轮完整点击流程通过。
- 本次真实连接点击验收使用普通 PTY；未额外启动真实 tmux/zellij 会话。共享输入状态与发送队列由定向测试覆盖，不据此宣称两个 provider 的远端集成验收通过。
- 模拟器录音/权限及真实音频转写未验收。语音视觉状态通过生产组件注入状态渲染，错误和过期回调通过单元测试验证。
- 离屏小窗口中的原生多行 TextField 长文本截图存在滚动位置偏移；该夹具只用于多行高度上限断言。多行视觉结论以真实 App 窗口的 XCUITest 截图为准，不将离屏截图当作实际终端效果。
