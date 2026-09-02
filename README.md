# Conn

Conn 是一款纯客户端 iOS 服务器连接与运维 App，围绕“连接 → 观测 → 处置”组织能力：通过 SSH 管理主机，查看系统指标、Docker、日志和文件，执行脚本，并提供普通 PTY、tmux、zellij 终端体验。

所有数据默认只保存在本机：密码和私钥存储在 Keychain，配置和运行记录存储在本地 SQLite，不依赖服务端、账号体系或云端同步。

## 项目状态

- 产品平台：iOS 17.0+
- 工程语言：Swift 5 language mode
- UI：SwiftUI，终端视图桥接 SwiftTerm
- SSH：协议层与 Citadel 引擎适配层分离
- 数据库：GRDB，本地单一完整 `SchemaV1`
- 支持语言：简体中文、繁体中文、英语、日语、韩语
- 持久终端：通过 provider-neutral registry 接入 tmux、zellij；provider 配置和操作不直接耦合页面
- 远端平台：Linux/macOS 采集与能力适配已纳入架构；Windows 等平台需以对应适配器和测试覆盖为准，不因枚举存在就宣称完整支持

当前版本仍处于持续开发阶段。具体产品范围以 [产品需求文档](docs/产品需求文档.md) 为准，具体架构以 [技术实现方案](docs/技术实现方案.md) 为准。

## 目录结构

```text
Conn/
├── Conn/                         # App 组装根、SwiftUI 页面、路由和本地化
├── ConnTests/                    # App 层单元测试
└── ConnUITests/                  # 真机/模拟器 XCUITest
Packages/
├── ConnPackages/                 # 单一 SPM package，多模块 target
│   ├── Sources/ConnKit            # 领域模型和协议
│   ├── Sources/ConnStore          # GRDB 本地存储
│   ├── Sources/ConnSSH            # SSH 抽象、Mock 和远端能力
│   ├── Sources/ConnSSHCitadel     # Citadel 引擎适配
│   ├── Sources/ConnMonitor        # 主机指标采集和解析
│   ├── Sources/ConnMultiplexer    # tmux/zellij provider-neutral 能力
│   ├── Sources/ConnTerminal       # SwiftTerm 和终端交互
│   ├── Sources/ConnOps             # Docker、服务和日志
│   ├── Sources/ConnRunner          # 脚本执行管线
│   ├── Sources/ConnEditor          # 代码编辑器
│   └── Sources/ConnUI              # 设计系统组件
└── Vendor/                        # 仓库内审计边界的第三方源码包
docs/                              # PRD、技术方案、设计规范和专项设计
Tooling/run_sim.sh                 # 构建、安装、启动和截图辅助脚本
```

## 架构原则

### 依赖方向

App 组装根负责注入 repository、SSH transport、monitor、terminal coordinator 和 provider registry。领域与协议层不依赖 SwiftUI/UIKit；页面不直接访问 GRDB、Citadel 或远端命令。

```text
SwiftUI App
    ↓ dependency injection
ConnKit / ConnStore / ConnSSH / ConnMonitor / ConnOps / ConnRunner
    ↓
ConnMultiplexer / ConnTerminal / ConnEditor / ConnUI
    ↓
Citadel、SwiftTerm、GRDB 和远端 Shell
```

新增代码应遵循已有 target 边界，而不是为了快速修复把逻辑复制到页面层。

### SSH、平台和脚本

SSH 连接、远端 Shell 初始化、平台画像和能力报告是不同层次：

- SSH transport 负责通道生命周期、超时、认证和重连。
- Shell 初始化负责加载远端用户环境，不应依赖固定 `/bin/bash` 或单一平台路径。
- 平台画像描述 Linux/macOS/Windows 等事实；能力状态描述 Docker、SFTP、日志或持久终端是否可用。
- 用户脚本默认是 POSIX shell，不要求声明平台；平台差异由执行环境和能力适配器处理。

### 终端和持久终端

普通 PTY、tmux、zellij 共用终端页面，但有不同的权威状态来源：普通 PTY 由本地终端模拟器维护显示缓冲区，持久终端可在重新连接时从远端恢复 workspace、window、pane 或 tab 状态。

provider 的检测、attach、重连、滚动、窗口/pane 操作和删除语义必须保持在 `ConnMultiplexer`，终端 UI 只消费统一 descriptor、能力和 typed action。所有同一 provider 的控制操作必须经过串行队列，避免快速点击、键盘 resize 和前后台恢复互相覆盖。

## 本地数据边界

| 数据 | 存储位置 |
|---|---|
| 主机连接配置、分组、脚本元数据和运行历史 | 本地 SQLite/GRDB |
| 密码和私钥材料 | 系统 Keychain |
| Host key 指纹 | 本地 SQLite/GRDB |
| 活跃 PTY、SwiftTerm 显示状态和临时选区 | 运行时内存 |
| 可恢复持久终端的本地入口/书签 | 仅保存恢复所需元数据，不保存远端终端内容 |

开发阶段只维护一份完整 `SchemaV1`，不为开发期旧库增加 v2–v6 迁移。数据库初始化失败时使用 App 提供的本地重试/重建路径；不要把删除用户数据作为普通启动兜底，也不要把 Keychain 凭据复制到 SQLite。

## 开发环境

需要：

- macOS + Xcode（包含 iOS 17 或更高平台支持）
- Swift 5.10 toolchain
- 可选：已开启开发者模式并连接的 iPhone/iPad，用于真机 XCUITest
- 可选：已授权的 Linux/macOS 测试主机，用于 SSH、PTY、tmux/zellij 和采集兼容性验收

查看工程 target 和 scheme：

```bash
xcodebuild -list -project Conn/Conn.xcodeproj
```

## 构建与运行

### Xcode

打开 `Conn.xcworkspace`，选择 `Conn` scheme 和用户当前明确使用的设备运行。workspace 同时包含 App 工程和本地 `ConnPackages` package。

### 模拟器辅助脚本

`Tooling/run_sim.sh` 用于构建、安装、启动和截图。它不是测试命令；必须显式指定用户当前已启动的模拟器，避免脚本默认选择旧设备：

```bash
DEVICE="<当前已启动模拟器 UDID>" Tooling/run_sim.sh /tmp/conn.png
```

查看设备：

```bash
xcrun xctrace list devices
xcrun simctl list devices booted
```

不要为了运行脚本启动、克隆、抹掉或关闭其他模拟器。真机不能使用 `simctl`，应通过 Xcode/XCUITest 部署和操作。

## 测试

### 1. 包单元测试

```bash
swift test --package-path Packages/ConnPackages
```

定向测试示例：

```bash
swift test --package-path Packages/ConnPackages --filter TerminalDirectionPadTests
swift test --package-path Packages/ConnPackages --filter TmuxProviderTests
swift test --package-path Packages/ConnPackages --filter ZellijProviderTests
```

### 2. App 测试

先通过 `xcrun xctrace list devices` 获取当前设备 UDID，再执行：

```bash
TEST_DEVICE_UDID="<当前设备 UDID>"
xcodebuild test \
  -project Conn/Conn.xcodeproj \
  -scheme Conn \
  -destination "id=$TEST_DEVICE_UDID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnTests
```

### 3. 真机/模拟器 UI 点击测试

涉及页面导航、按钮、弹窗、键盘、手势、终端滚动或选区，都必须运行 XCUITest：

```bash
xcodebuild test \
  -project Conn/Conn.xcodeproj \
  -scheme Conn \
  -destination "id=$TEST_DEVICE_UDID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnUITests
```

单个终端入口测试：

```bash
xcodebuild test \
  -project Conn/Conn.xcodeproj \
  -scheme Conn \
  -destination "id=$TEST_DEVICE_UDID" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ConnUITests/ConnUITests/testTerminalCenterOpensWithoutCrashing
```

UI 测试应通过 accessibility identifier 和语义控件点击，不以坐标点击或截图对比作为默认验证方式。测试报告必须注明是真机还是模拟器、设备名称、UDID、执行的测试选择器和结果。

### 4. 真实远端验收

Mock 测试覆盖大多数状态机和错误路径；真实主机只用于验证 SSH/PTY、Shell 初始化、macOS/Linux 采集、tmux Control Mode、zellij attach 和实际命令行为。测试主机凭据、私钥、IP 和输出不得进入仓库或日志。

如果完整测试因设备签名、CoreSimulator/XCTest 服务、网络或测试运行器异常失败，应如实记录失败层级；定向测试通过不能写成全量测试通过。

## 文案与本地化

App 层统一使用 `L()` 读取本地化文本，支持 `zh-Hans`、`zh-Hant`、`en`、`ja`、`ko`。新增文案必须同步更新五种语言并通过现有覆盖测试；format 占位符必须保持一致。命令、路径、主机名、provider ID 和远程输出保持原文。

## 文档地图

| 文档 | 用途 |
|---|---|
| [AGENTS.md](AGENTS.md) | coding agent 必须遵循的开发、测试和交付规则 |
| [产品需求文档](docs/产品需求文档.md) | 产品范围、优先级、竞品和商业化约束 |
| [技术实现方案](docs/技术实现方案.md) | 架构、模块、依赖、数据模型和验收策略 |
| [设计规范](docs/设计规范.md) | 设计令牌、组件、布局、动效和可访问性 |
| [docs/superpowers/specs/](docs/superpowers/specs/) | 已评审的专项设计与问题修复方案 |
| [docs/superpowers/plans/](docs/superpowers/plans/) | 分阶段实现计划和执行记录 |

Markdown 是源文件；需要 HTML 版本时使用 `Tooling/build_doc_html.py` 生成，不要手工修改生成文件。

## 提交前检查

- [ ] `git status --short` 已确认没有误改和临时文件。
- [ ] 相关正常、失败、取消和竞态路径有自动化测试。
- [ ] UI/终端/键盘/手势改动已在当前用户设备上运行 XCUITest。
- [ ] 所有新增文案都通过 `L()` 并补齐五种语言。
- [ ] `git diff --check` 通过。
- [ ] 测试命令、设备、结果和未执行项已记录。
- [ ] 未把密码、私钥、IP、测试日志或构建产物提交到仓库。
