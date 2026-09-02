# Conn 工程协作规范

本文档是仓库内 coding agent 的执行规范，适用于功能开发、缺陷修复、重构、UI 调整和测试。用户当前明确要求与本文档冲突时，以用户要求为准，但须在交付说明中记录影响。

## 1. 开始工作前

1. 执行 `git status --short` 和 `git diff --stat`，确认工作区状态。
2. 保留用户已有改动，只修改当前任务涉及的文件；禁止使用 `git reset --hard`、`git checkout --` 等不可恢复操作。
3. 阅读与任务直接相关的 `docs/产品需求文档.md`、`docs/技术实现方案.md`、`docs/设计规范.md`、`docs/prototypes/index.html` 及 `docs/superpowers/specs/`、`docs/superpowers/plans/` 中的专项文档。
4. 先定位根因，再决定改动范围。终端、键盘、手势、连接和数据库问题不得仅凭截图或单次现象下结论。
5. 使用 `apply_patch` 修改源文件和文档，不要用 shell 重定向或临时脚本覆盖仓库文件。

## 2. 工程边界与架构约束

### 2.1 产品边界

- Conn 是纯客户端 iOS App，产品基线为 iOS 17.0+，Swift 5 language mode。
- 不引入服务端、账号体系、云端同步、告警推送或遥测；数据默认只留在设备本地。
- 密码、私钥等敏感材料只进入 Keychain；SQLite 只保存必要的配置、元数据和引用，不保存私钥明文。
- 当前开发期只维护一份完整的 `SchemaV1`。不要为了兼容开发阶段旧结构增加 v2–v6 迁移或隐藏兼容逻辑；进入已有用户数据的发布阶段后，须先取得明确的数据迁移决策并补齐迁移测试。
- 远端原始输出、Shell 命令、主机名、地址和路径保持原文，不作为普通 UI 文案翻译。

### 2.2 模块职责

| 模块 | 职责 |
|---|---|
| `Conn/Conn` | App 组装根、SwiftUI 页面、路由、依赖注入和本地化入口 |
| `ConnKit` | 领域模型、协议、解析和值对象；不依赖 UIKit |
| `ConnStore` | GRDB 数据库和 repository；不负责 SSH 或 UI |
| `ConnSSH` | SSH/远程执行抽象、Mock、超时、重连和远端环境解析 |
| `ConnSSHCitadel` | Citadel 引擎适配；不向协议层泄漏 Citadel 类型 |
| `ConnMonitor` | Linux/macOS 采集脚本、解析、CPU 差分和调度 |
| `ConnOps` | Docker、日志和服务操作模型 |
| `ConnRunner` | 脚本渲染、执行计划、危险确认和运行历史 |
| `ConnMultiplexer` | provider-neutral 持久终端协议、registry、状态和操作语义 |
| `ConnTerminal` | SwiftTerm 桥接、终端会话、滚动/选区、快捷键和 provider 交互 |
| `ConnEditor` | 离线代码编辑器和语法高亮 |
| `ConnUI` | 无业务状态的设计系统组件和令牌 |

跨层能力必须通过协议和依赖注入连接。App 页面不得直接拼接 tmux/zellij 命令、访问 GRDB 或创建具体 SSH 引擎。

### 2.3 持久终端和远端平台

- tmux、zellij 等 provider 通过 `PersistentTerminalProviderRegistry` 和 descriptor 接入；新增 provider 不复制终端页面或数据库逻辑。
- provider 可用性必须由实际探测/握手结果确认，不能只根据版本号、操作系统名或固定路径推断。
- provider 不可用时呈现明确的不可用状态，不得静默降级成普通 PTY。
- provider 操作通过统一的 typed action 和队列串行执行，避免键盘 resize、窗口切换、pane 操作和重连并发写入同一控制通道。
- 普通 PTY 使用 SwiftTerm 原生滚动和选区；tmux 等持久终端使用远端权威历史/滚动语义。两者共享终端视图和交互边界，不得替换成普通 `TextView` 实现选区。
- `RemotePlatformKind` 是远端能力画像，不是脚本编辑器中的用户声明字段。平台差异封装在能力适配器和解析器中，不在 UI 中增加平台硬编码分支。

## 3. UI、交互和本地化

- UI 调整以 `docs/设计规范.md` 和 `docs/prototypes/index.html` 为基准，保持安全区域、触控热区、键盘避让、深浅色主题和 Dynamic Type 一致。
- 新增或修改用户可见文案必须通过 `L()`，同步补齐 `zh-Hans`、`zh-Hant`、`en`、`ja`、`ko` 五种语言；禁止把源语言回退当作翻译完成。
- 文案应简洁、准确、专业；空状态使用“暂无…”，搜索无结果使用“未找到匹配的…”，避免口语化说明。
- UI 测试优先使用稳定的 `accessibilityIdentifier` 和语义角色，不依赖固定屏幕坐标、截图像素或当前语言的可见文字。
- 新增按钮、弹窗、导航、键盘、手势或 loading 状态时，必须同时考虑可访问性、安全区域、键盘开关、前后台恢复、重复点击和失败反馈。

## 4. 测试分层和执行方法

所有功能开发和缺陷修复都必须新增或更新自动化测试，覆盖正常路径、错误路径和真实回归风险；仅编译成功不能作为完成依据。

### 4.1 发现测试设备

物理设备和模拟器都可以作为 XCUITest 目标。不要假设设备类型，也不要写死旧 UDID。

```bash
# 查看在线真机、Mac 和模拟器
xcrun xctrace list devices

# 只查看当前已启动的模拟器
xcrun simctl list devices booted
```

选择用户当前已连接/已启动且明确用于本次验收的一台设备，并记录 UDID：

```bash
TEST_DEVICE_UDID="<xcrun xctrace list devices 输出中的 UDID>"
```

规则：

- 默认复用用户已经启动的模拟器，或用户已经连接并授权使用的真机。
- 不得 clone、创建、启动、重启、抹掉、关闭或切换到其他设备来绕过测试问题。
- 真机 XCUITest 需要开发者模式、签名和 provisioning profile；失败时报告真实原因，不要换设备掩盖问题。
- 测试结束后不接管设备生命周期；XCUITest 为运行测试而重启被测 App 不属于改变设备生命周期。

### 4.2 Swift Package 单元测试

包内纯逻辑测试优先在 host 上运行：

```bash
swift test --package-path Packages/ConnPackages
```

变更范围较小时先跑定向 suite，再跑全量：

```bash
swift test --package-path Packages/ConnPackages --filter TerminalDirectionPadTests
swift test --package-path Packages/ConnPackages --filter ZellijProviderTests
```

包测试覆盖模型、解析器、repository、provider 状态机、命令渲染、队列和错误映射；不要把远端 SSH 或 UI 依赖塞进纯单元测试。

### 4.3 App 单元测试

App 层测试使用当前目标设备，固定关闭并行测试，避免 Xcode 创建 Clone：

```bash
xcodebuild test \
  -project Conn/Conn.xcodeproj \
  -scheme Conn \
  -destination "id=$TEST_DEVICE_UDID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests
```

可按 suite 缩小范围，例如 `-only-testing:ConnTests/TerminalLayoutTests`。

### 4.4 XCUITest 真机/模拟器点击验收

涉及页面、弹窗、导航、键盘、终端、手势或用户可见状态时，必须运行 UI 测试：

```bash
xcodebuild test \
  -project Conn/Conn.xcodeproj \
  -scheme Conn \
  -destination "id=$TEST_DEVICE_UDID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnUITests
```

终端入口的最小验收示例：

```bash
xcodebuild test \
  -project Conn/Conn.xcodeproj \
  -scheme Conn \
  -destination "id=$TEST_DEVICE_UDID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnUITests/ConnUITests/testTerminalCenterOpensWithoutCrashing
```

UI 测试要求：

1. 使用 `XCUIApplication`、语义控件和 accessibility identifier 定位元素。
2. 对点击、长按、滑动、键盘开关和前后台恢复，验证操作结果和 App 进程状态，不只截图。
3. 终端测试覆盖受影响的普通 PTY、tmux/zellij 路径；没有远端会话时，不在生产代码中植入测试账号或隐藏入口。
4. 依赖真实主机状态时写明前置条件或跳过原因；“找不到元素”不能无条件吞掉。
5. 新增 UI 控件时，在生产视图上增加稳定 identifier，并在 XCUITest 中使用它；不要用屏幕坐标作为默认方案。

### 4.5 真机和真实远端验收

真机证明 iOS 端部署、权限、键盘、手势和 UI 生命周期，不能替代远端平台集成测试。涉及 macOS/Linux/tmux/zellij 时，额外使用已授权测试主机：

- 不把 IP、用户名、密码、私钥、host key 或测试数据写入仓库、测试输出和截图。
- 通过 transport/fixture 覆盖大多数路径；真实主机只用于协议兼容性、PTY、Control Mode、远端 shell 初始化和实际工具行为。
- 真实主机测试必须设置连接、命令和整体超时，成功、失败、取消都关闭 SSH/SFTP/PTY 通道。
- macOS 与 Linux 的采集差异必须分别覆盖；不能把 Linux 命令成功当作 macOS 兼容证明。

## 5. 测试失败、日志和完成证据

- 区分代码断言失败、编译/签名失败、设备不可用、远端环境失败和测试运行器崩溃。
- 全量测试因测试运行器 `signal 11` 或设备服务异常中止时，不得写“测试通过”；保留日志，补跑本次变更相关的定向测试，并在交付说明中列出全量未通过及原因。
- 推荐保存临时输出到 `/tmp`：

  ```bash
  set -o pipefail
  xcodebuild test ... 2>&1 | tee /tmp/conn-xcode-test.log
  ```

- 每轮 Xcode 构建/测试后执行 `git status --short`。如果出现 `project.pbxproj`、资源目录或字符串目录变更，先检查 diff，确认是否属于本次任务；禁止盲目恢复用户改动。
- 完成前执行 `git diff --check`，并核对新增测试确实被目标命令执行。
- 交付说明必须包含：改动摘要、已知限制、实际测试命令、设备名称和 UDID、每项结果，以及未执行或失败的测试。

## 6. 数据库和本地数据

- `AppDatabase.inMemory()` 用于单元测试；App 生产库位于 Application Support 下的 `Conn/conn.sqlite`。
- 开发阶段修改完整 schema 时更新 `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift`，通过测试数据库和 App 重试重建验证；不要新增无明确决策的增量迁移。
- 删除或重建前必须确认目标是测试库/开发库，不得递归删除工作区、用户目录或未确认的数据目录。
- Keychain 与 SQLite 的一致性由 repository、补偿逻辑和测试保证；不要为方便 UI 把凭据复制进数据库。

## 7. Git 和交付

- 默认不创建提交、不 push、不创建 PR；只有用户明确要求时才执行。
- 提交前复查 `git diff`、`git diff --check` 和测试日志，确保没有临时文件、凭据、构建产物或无关格式化。
- 不为“看起来更完整”扩大改动范围；与任务无关的真实问题记录在交付说明中，另开任务处理。

## 8. 完成检查清单

- [ ] 已检查并保留工作区原有改动。
- [ ] 已阅读相关设计文档，未违反产品边界和模块职责。
- [ ] 正常、失败、取消或竞态路径有对应自动化测试。
- [ ] UI/终端/键盘/手势变更有 XCUITest，并使用稳定 identifier。
- [ ] 已在当前用户设备上用精确 UDID 验收，并记录真机/模拟器类型和结果。
- [ ] 新增或修改文案已通过 `L()`，五种语言和本地化覆盖测试已更新。
- [ ] `git diff --check` 通过，工作区无无关生成文件。
- [ ] 交付说明没有把未执行、失败或条件跳过的测试写成通过。
