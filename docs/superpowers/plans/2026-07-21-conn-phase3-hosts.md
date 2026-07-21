# Conn Phase 3 — 主机管理 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 让「主机」Tab 成为完整的连接管理——主机 CRUD、分组标签筛选、`ssh` 命令粘贴识别、连接测试与诊断树（S16），并在 App 内真连一台服务器验证 Phase 2 引擎。

**Architecture:** 沿用 `@Observable @MainActor ViewModel + 注入 Repository` 模式。粘贴解析、表单草稿验证是纯逻辑放 ConnKit（host 可测）。凭据存取新建 ConnCrypto target（Keychain 密码/passphrase 最小切片，Phase 5 扩展为密钥管家）。连接测试复用 Phase 2 的 ConnectionManager。

**Tech Stack:** SwiftUI、Security.framework（Keychain）、Phase 2 的 ConnSSH 栈。

---

## Global Constraints（继承前序）

- iOS 17.0、Swift 5 语言模式。
- **凭据只进 Keychain**（红线）——`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，密文绝不入 SQLite。
- 设计裁决：原型 CSS 为真值 + 三条例外（触控热区 44pt、价格以 PRD 为准、深色令牌已补）。
- 相关原型屏：S2 主机列表、S16 连接诊断树、S3 主机详情概览（本 Phase 只做导航框架，监控数据 Phase 7）。
- 新增主机表单原型未出稿（冲突台账 C55），按 PRD §5.1 实现：**只必填「地址 + 用户名 + 认证」三项**，其余折叠。

---

## 文件结构

```
Packages/ConnPackages/
├── Package.swift                       # + ConnCrypto target
├── Sources/
│   ├── ConnKit/
│   │   ├── Parsing/SSHCommandParser.swift   # ssh 命令粘贴识别（纯函数）
│   │   ├── Models/HostDraft.swift           # 表单草稿 + 验证
│   │   └── Repositories/HostGroupRepository.swift
│   ├── ConnCrypto/                          # 新 target：Keychain 凭据（最小切片）
│   │   ├── CredentialStore.swift            # 协议 + 错误
│   │   └── KeychainCredentialStore.swift    # Security.framework 实现
│   └── ConnStore/DAO/HostGroupStore.swift   # 分组 CRUD
└── Tests/
    ├── ConnKitTests/SSHCommandParserTests.swift
    ├── ConnKitTests/HostDraftTests.swift
    └── ConnCryptoTests/                      # 内存替身测试（Keychain 真机验证）

Conn/Conn/Hosts/                        # Feature 视图（App target）
├── HostListView.swift + HostListViewModel.swift    # S2
├── HostFormView.swift + HostFormViewModel.swift    # 新增/编辑 sheet
├── DiagnosticsView.swift + ConnectionTester.swift  # S16
└── HostDetailView.swift                            # S3 框架（概览占位）
```

---

## Task 分解

### Task 1: SSHCommandParser（粘贴识别）— ConnKit，纯函数

PRD §5.1：粘贴 `ssh root@1.2.3.4 -p 2222` 自动识别填充。
- 解析 `ssh [user@]host [-p port] [-i keyfile]`，返回 `HostDraft`
- 覆盖：`ssh host`、`ssh user@host`、`-p port`、`ssh://user@host:port` URL 形式、含选项乱序、非 ssh 文本返回 nil
- TDD 先行，host 可测

**Produces:** `SSHCommandParser.parse(_ text: String) -> HostDraft?`

### Task 2: HostDraft（表单草稿 + 验证）— ConnKit

- `HostDraft`：可变字段（name/address/port/username/authKind/…），与 `Host` 双向转换
- `validate() -> [HostDraft.Field: String]`（字段 → 错误信息）；地址/用户名必填，端口 1–65535
- `toHost()` / `init(from: Host)`

### Task 3: ConnCrypto — Keychain 凭据（最小切片）

- 新 target ConnCrypto（依赖 ConnKit）
- `CredentialStore` 协议：`setPassword/password/deletePassword(for hostID:)`、passphrase 同理
- `KeychainCredentialStore`：Security.framework，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，key 形如 `conn.host.<uuid>.password`
- `InMemoryCredentialStore`（测试替身）
- Phase 5 会在此 target 加密钥生成/SE/部署，本 Phase 只做密码/passphrase 存取

### Task 4: HostGroupStore + 分组 CRUD — ConnStore

- `HostGroupRepository` 协议（ConnKit）+ `HostGroupStore`（GRDB）
- 主机按分组读取；分组增删改

### Task 5: 主机列表 S2 — HostListView + ViewModel

- 搜索框、分组分区、标签筛选 chip、免费版限额 banner（3 台，用 Phase 10 的 Gate 前先硬编码占位）
- 用 ConnListRow + ConnStatusDot 渲染（复用 Phase 1b 组件）
- 左滑：连接/编辑/删除
- 空态用 EmptyState 双出口

### Task 6: 主机表单 — HostFormView + ViewModel

- sheet 呈现；顶部「粘贴识别」入口调 SSHCommandParser
- 必填三项 + 折叠的高级项（端口/分组/标签/图标色/备注/跳板链）
- 密码/passphrase 存 CredentialStore；保存写 HostRepository
- 保存前「连接测试」按钮 → Task 7

### Task 7: 连接测试 + 诊断树 S16 — ConnectionTester + DiagnosticsView

- `ConnectionTester`：尝试连接，捕获 `SSHError` 映射为诊断步骤
- 分步（简化版）：地址可解析 → 端口可达 → 认证通过 → 指纹信任；每步 ok/fail/pending
- 失败步骤给出 SSHError.diagnosis 文案
- S16 用 ConnCard + 步骤卡渲染

### Task 8: 主机详情框架 S3 — HostDetailView

- 从列表 push 进入；顶部主机名 + StatusPill
- 分段控件 5 段（概览/终端/文件/Docker/日志）——本 Phase 只做概览段的框架
- 概览段：MetricGauge ×3 占位（数据 Phase 7）、快捷动作 ActionTile
- 其余段显示「Phase N 实现」占位

### Task 9: 接入 App + 真机连接验证

- 主机 Tab 换成 HostListView
- AppDependencies 注入 CredentialStore
- **真机验证**：用 Spike 容器（127.0.0.1:2202, deploy, 密码）录入一台主机 → 连接测试通过 → 详情页可见

---

## 验收

- [ ] host 单测覆盖 SSHCommandParser（含 URL/乱序/非法）、HostDraft 验证、CredentialStore 替身
- [ ] 主机 CRUD 全链路（增删改查 + 分组标签）在模拟器可用
- [ ] 粘贴 `ssh deploy@127.0.0.1 -p 2202` 自动填充
- [ ] 连接测试对 Spike 容器成功，对不存在主机给出诊断
- [ ] SwiftLint 0 error；无凭据入日志/入 SQLite
