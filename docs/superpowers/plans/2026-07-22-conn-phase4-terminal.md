# Conn Phase 4 — 终端 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development。步骤用 `- [ ]` 复选框跟踪。

**Goal:** PRD「体验生命线」——SwiftTerm 桥接的可交互终端，多会话、加速键条、危险命令拦截，并做中文 IME 专项（Spike S2）。

**Architecture:** `ConnTerminal` target（SwiftTerm + ConnSSH，iOS-only）。PTY 通道走 Phase 2 的 `ShellChannel` 协议——Citadel 侧用 `withPTY` 实现 `CitadelShellChannel`。`TerminalSession` actor 桥接通道 IO 与 SwiftTerm，输出按 16ms 合帧（≤60fps）。SwiftTerm 无 SwiftUI wrapper，自写 `UIViewRepresentable`。

**Tech Stack:** SwiftTerm 1.15.0、Citadel withPTY、UIKit 桥接、Swift 5。

---

## Global Constraints（继承）

- iOS 17.0、Swift 5 语言模式。
- SwiftTerm `from: "1.14.0"`（实解析 1.15.0）——必须 ≥1.8.0 才能 iOS 中文输入；**#170 无组字内联候选预览**（S2 预案大概率要真做包装层）。
- Citadel `withPTY` 是闭包作用域式（PTY 随闭包返回而关闭）；长生命周期会话需用延续取出 `TTYStdinWriter`。
- 危险命令拦截在 Runner 层做语义判断，传输层不做（技术方案 §4.1/§4.2）。
- 相关原型：S4 终端会话中心。

---

## 关键 API（已从源码核实）

- `SwiftTerm.TerminalView: UIScrollView`；`.terminalDelegate`；`feed(byteArray: ArraySlice<UInt8>)`、`feed(text:)`；`getTerminal()`。
- `TerminalViewDelegate` 必实现：`send(source:data: ArraySlice<UInt8>)`、`sizeChanged(source:newCols:newRows:)`；其余有默认实现。
- Citadel `client.withPTY(_ request: PseudoTerminalRequest, environment:, perform: (TTYOutput, TTYStdinWriter) async throws -> Void)`。
  - `TTYOutput: AsyncSequence`，元素 `ExecCommandOutput`（`.stdout`/`.stderr` ByteBuffer）。
  - `TTYStdinWriter.write(_ buffer: ByteBuffer)`、`changeSize(cols:rows:pixelWidth:pixelHeight:)`（SIGWINCH）。
  - `PseudoTerminalRequest(wantReply:term:terminalCharacterWidth:terminalRowHeight:...)`。

---

## 文件结构

```
Sources/ConnTerminal/
├── TerminalSession.swift          # actor：ShellChannel ⇄ SwiftTerm，16ms 合帧
├── TerminalHostingView.swift      # UIViewRepresentable 包装 TerminalView
├── TerminalTheme.swift            # 配色（Dracula/Solarized… 内置）
├── TerminalKeybarController.swift # inputAccessoryView 加速键条
├── TerminalSessionStore.swift     # 多会话管理（@Observable）
└── DangerCommandRules.swift       # 危险命令正则（放 ConnSSH? 见下）
Sources/ConnSSHCitadel/
└── CitadelShellChannel.swift      # withPTY → ShellChannel
Conn/Conn/Terminal/
├── TerminalScreen.swift           # S4 会话中心 UI
└── TerminalTabBar.swift           # 会话标签切换
```

---

## Task 分解

### Phase 4a：PTY 通道 + SwiftTerm 桥接 + 单会话可跑

**Task 1: CitadelShellChannel** — ConnSSHCitadel
用 `withPTY` 在 Task 中建 PTY，用 `CheckedContinuation` 取出 `TTYStdinWriter`，`TTYOutput` 桥接到 `output` 流。实现 `ShellChannel.write/resize/output/close`。`CitadelSession.openShell` 返回它。集成测试连 Docker 跑 shell。

**Task 2: DangerCommandRules** — ConnSSH（纯逻辑，host 可测）
正则规则表（`rm -rf /`、`mkfs`、`dd of=/dev/`、fork bomb）+ 生产标签判定。`evaluate(command:isProduction:) -> DangerVerdict`。TDD 覆盖。

**Task 3: TerminalSession** — ConnTerminal
actor 桥接 `ShellChannel` 与一个「feed 回调」。输出 16ms 合帧批量投递（避免逐字节掉帧）。用 MockShellChannel 单测合帧与写入。

**Task 4: TerminalHostingView + TerminalTheme** — ConnTerminal
`UIViewRepresentable` 包装 `TerminalView`，实现 delegate（send → session.write，sizeChanged → channel.resize）。session 输出 → `feed(byteArray:)`。内置 Dracula 等主题。

**Task 5: 接入 App 单会话 + 真机验证**
主机详情「终端」段或终端 Tab 打开一个真实 shell，连 Spike 容器跑 `ls`/`vim`，截图验证。

### Phase 4b：多会话 + 加速键条 + 危险命令 UI

**Task 6: TerminalSessionStore** — 多标签会话，后台保持，卡片切换（S4）。
**Task 7: TerminalKeybarController** — inputAccessoryView 挂 SwiftUI 键条（Esc/Tab/Ctrl 粘滞/方向键/`|`/`-`/`~`），可横滑。
**Task 8: 危险命令确认弹层** — 回车前匹配 DangerCommandRules，prod 标签二次确认。

### Phase 4c：中文 IME 专项（Spike S2）

**Task 9: 中文输入验证与包装** — 系统拼音键盘 markedText 全程不污染终端流；vim 中文编辑；候选条不遮挡。若 SwiftTerm 默认行为有脏字节，做自定义 `UITextInput` 拦截层。结论回写技术方案 §6（S2）。

---

## 验收

- [ ] 真机 vim/htop/ls 渲染与按键正确
- [ ] 中文输入拼音→上屏全程不污染终端流（S2 出口标准）
- [ ] 多会话切换后台保持
- [ ] 危险命令回车前拦截，prod 主机二次确认
- [ ] DangerCommandRules host 单测；TerminalSession 合帧单测
- [ ] SwiftLint 0 error
