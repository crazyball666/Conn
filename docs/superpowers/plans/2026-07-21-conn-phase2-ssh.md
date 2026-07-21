# Conn Phase 2 — SSH 连接引擎 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 executing-plans。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 落地 `SSHTransport` 协议层、可在 host 上完整单测的 `MockSSHTransport`、基于 Citadel 的 `CitadelTransport` 真实实现、`ConnectionManager` 池化 actor、跳板链、TOFU 指纹库与断线重连。

**Architecture:** 引擎藏在 `SSHTransport` 协议之后（技术方案 §4.1）。协议层与 Mock 零 UIKit、零 Citadel 依赖 → host 上 `swift test` 秒级验证。Citadel 实现单独一个 target，用 `Spikes/S1-ssh-matrix/` 的 Docker 矩阵做集成测试。

**Tech Stack:** Citadel 0.12.1、SwiftNIO、Swift 5 语言模式、Swift Testing。

---

## Global Constraints（继承 Phase 1，本 Phase 新增项加粗）

- iOS 17.0 基线、Swift 5 语言模式、Xcode 26。
- **Citadel `from: "0.12.1"`**——引入前先确认它把项目下限锁死 iOS 17.0（R4）。
- 红线：网络请求只允许 SSH 目标主机 / iCloud / AI 端点。SSH 引擎的所有出站连接必须指向用户配置的主机（含跳板链各级）。
- 凭据从 Keychain 取，**绝不出现在日志**（技术方案 §4.7）。

### S1 实测结论（本 Phase 的选型依据，来自技术方案 §6.1）

| 事实 | 对实现的约束 |
|---|---|
| ed25519 全 5 服务端 100% 可用 | 默认密钥类型；集成测试主路径用 ed25519 |
| Citadel 缺 rsa-sha2 → RSA 私钥连 Ubuntu22+ 失败 | RSA 认证失败时给「建议改用 ed25519」诊断；集成测试须覆盖此失败态并断言诊断文案 |
| 老服务器（CentOS7）需 group14-sha1 KEX + CBC + ssh-rsa host key | 连接时传 `algorithms: .all`；集成测试覆盖 centos7:2204 |
| Citadel 无 keyboard-interactive（R3） | 协议层预留 `.keyboardInteractive` auth case，Citadel 实现抛 `.unsupportedByEngine`，UI 提示「该服务器需要交互式认证，当前版本暂不支持」 |
| Citadel 依赖个人 fork（R1） | 引入后在 PR 说明记录；Phase 2 末评估是否 vendoring |

### 测试环境（已就绪）

`Spikes/S1-ssh-matrix/` 7 容器，端口 2201–2206。凭据：用户 `root`/`deploy`，密码 `conntest123`，密钥在 `keys/`。`docker compose start` 启动，`teardown.sh` 清理。

---

## 文件结构

```
Packages/ConnPackages/
├── Package.swift                    # 改：+ ConnSSH target、+ Citadel 依赖
├── Sources/
│   ├── ConnSSH/                     # 协议层 + Mock + ConnectionManager（零 Citadel）
│   │   ├── SSHTransport.swift       # 协议：SSHTransport / SSHSession
│   │   ├── SSHTypes.swift           # SSHEndpoint / SSHAuth / HostKeyPolicy / ExecResult / 错误
│   │   ├── HostKeyStore.swift       # TOFU 指纹库协议 + 内存实现
│   │   ├── ConnectionManager.swift  # 池化 actor
│   │   ├── Reconnection.swift       # 指数退避策略
│   │   └── Mock/
│   │       └── MockSSHTransport.swift  # 脚本化假引擎（演示模式复用）
│   └── ConnSSHCitadel/              # Citadel 实现（单独 target，隔离依赖）
│       ├── CitadelTransport.swift
│       ├── CitadelSession.swift
│       ├── JumpChain.swift          # 跳板链嵌套隧道
│       └── AuthMapping.swift        # SSHAuth → Citadel 认证方法 + 诊断
└── Tests/
    ├── ConnSSHTests/                # host 可跑：Mock、指纹库、重连策略、错误诊断
    └── ConnSSHCitadelTests/         # 集成测试：连 Docker 矩阵（CI 用 SPIKE_HOST 门控）
```

**依赖方向**：`ConnSSHCitadel → ConnSSH → ConnKit`。ConnSSH 不依赖 Citadel（协议层可换引擎）。

---

## Phase 2a：协议层 + Mock + 管理器（host 可测，不引 Citadel）

### Task 1: SSH 类型与错误

**Files:**
- Modify: `Package.swift`（+ ConnSSH target）
- Create: `Sources/ConnSSH/SSHTypes.swift`
- Test: `Tests/ConnSSHTests/SSHErrorTests.swift`

**Interfaces:**
- Produces:
  - `SSHEndpoint { host: String, port: Int }`
  - `SSHAuth`（enum：`.password(String)` / `.key(SSHPrivateKeyMaterial)` / `.keyboardInteractive`）
  - `SSHPrivateKeyMaterial { kind: SSHKey.Kind, pem: String, passphrase: String? }`
  - `HostKeyPolicy`（enum：`.tofu` / `.strict(expectedFingerprint: String)` / `.acceptOnce`）
  - `ExecResult { exitCode: Int32, stdout: Data, stderr: Data }`
  - `SSHError: Error`（见下方 case 表），每个 case 带 `diagnosis: String`（「原因 + 下一步」，技术方案 §10.5）

- [ ] **Step 1: 写失败的测试**

```swift
import Testing
import ConnKit
@testable import ConnSSH

@Suite("SSHError 诊断文案")
struct SSHErrorTests {
    @Test("RSA 连现代服务器失败，诊断建议改用 ed25519")
    func rsaModernServerDiagnosis() {
        let error = SSHError.authFailed(reason: .rsaSha2Unsupported)
        #expect(error.diagnosis.contains("ed25519"))
        #expect(error.diagnosis.contains("原因"))
    }

    @Test("keyboard-interactive 不支持时给出明确说明")
    func keyboardInteractiveUnsupported() {
        let error = SSHError.unsupportedByEngine(.keyboardInteractive)
        #expect(error.diagnosis.contains("交互式"))
    }

    @Test("跳板链失败指明卡在第几级")
    func jumpChainFailurePointsToHop() {
        let error = SSHError.jumpChainFailed(hopIndex: 1, hopHost: "bastion")
        #expect(error.diagnosis.contains("bastion"))
        #expect(error.diagnosis.contains("第 2 级") || error.diagnosis.contains("第2级"))
    }
}
```

- [ ] **Step 2–4**: 加 ConnSSH target（`Package.swift`，依赖 ConnKit）；实现 `SSHTypes.swift`。`SSHError` case 表：
  - `.connectionRefused(endpoint:)` — 「无法连接 host:port：连接被拒绝。检查 sshd 是否运行、端口是否正确」
  - `.dnsFailed(host:)` — 「无法解析 host。检查主机地址拼写或 DNS」
  - `.timeout(endpoint:)` — 「连接 host:port 超时。检查防火墙或网络」
  - `.authFailed(reason:)`，`reason ∈ {.badCredentials, .rsaSha2Unsupported, .noAcceptedMethods}`
  - `.hostKeyMismatch(expected:actual:)` — 全屏阻断用
  - `.unsupportedByEngine(SSHAuth.Feature)` — keyboard-interactive 等
  - `.jumpChainFailed(hopIndex:hopHost:)`
  - `.channelClosed`
  运行测试转绿。commit。

### Task 2: HostKeyStore（TOFU 指纹库）

**Files:** `Sources/ConnSSH/HostKeyStore.swift`、`Tests/ConnSSHTests/HostKeyStoreTests.swift`

**Interfaces:**
- `protocol HostKeyStore: Sendable { func knownFingerprint(for: SSHEndpoint) -> String?; func remember(_ fingerprint: String, for: SSHEndpoint); func evaluate(_ presented: String, for: SSHEndpoint) -> HostKeyVerdict }`
- `HostKeyVerdict`（enum：`.trustedFirstUse` / `.matches` / `.mismatch(known: String)`）
- `InMemoryHostKeyStore`（host 测试用）；GRDB 实现（`known_host` 表）留到 Task 3

TDD：首次见到 → `.trustedFirstUse` 并入库；再见相同 → `.matches`；变更 → `.mismatch`。这是防降级攻击的核心（技术方案 §4.1），必须单测覆盖。

### Task 3: GRDBHostKeyStore

**Files:** `Sources/ConnStore/DAO/KnownHostStore.swift`（放 ConnStore，因依赖 GRDB）、测试
把 Task 2 的协议落到 `known_host` 表。ConnSSH 通过协议注入，不直接依赖 GRDB。

### Task 4: MockSSHTransport

**Files:** `Sources/ConnSSH/Mock/MockSSHTransport.swift`、`Tests/ConnSSHTests/MockSSHTransportTests.swift`

演示模式与 UI 测试复用同一实现（技术方案 §4.10）。要求：
- 完整实现 `SSHTransport` / `SSHSession` 协议
- 脚本化 shell：`ls`/`cd`/`cat`/`top`/`uptime`/`df`/`free`/`docker ps` 等 20 个假命令，确定性输出
- `exec` 返回预置结果；`execStream` 按行吐出、可注入延迟
- 可配置的失败注入（连接拒绝、认证失败、指纹变更）——供诊断树 UI 测试
- 假指标发生器（正弦 + 噪声，含一台「故障机」）留到 Phase 7/10，本 Task 只做命令层

TDD 覆盖：连接成功/各类失败注入、exec 确定性、execStream 分帧。

### Task 5: 重连策略

**Files:** `Sources/ConnSSH/Reconnection.swift`、测试
纯函数式退避：`ReconnectPolicy { func delays() -> [Duration] }` → `[1s, 2s, 4s]`（技术方案 §4.1）。host 可测，不涉网络。

### Task 6: ConnectionManager（池化 actor）

**Files:** `Sources/ConnSSH/ConnectionManager.swift`、测试
- `actor ConnectionManager`，注入 `SSHTransport` + `HostKeyStore`
- `session(for: Host)`：每主机复用 1 条连接（池化）；并发请求同一主机只建一次
- `disconnect(host:)`
- TDD 用 MockSSHTransport：验证池化（两次 `session(for:)` 返回同一实例）、并发去重、断开后重建

**Phase 2a 验收**：`swift test --filter ConnSSHTests` 全绿，host 上无需模拟器。ConnectionManager + Mock 可跑通「连接→exec→断开」全流程。

---

## Phase 2b：Citadel 真实实现 + 集成测试

### Task 7: 引入 Citadel + CitadelTransport 骨架

**Files:** `Package.swift`（+ Citadel 依赖、+ ConnSSHCitadel target）、`Sources/ConnSSHCitadel/CitadelTransport.swift`
- 加 `.package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1")`
- 确认 workspace 仍编译、iOS 17 仍是下限
- `CitadelTransport: SSHTransport`：`connect` 用 `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:algorithms:)`，**algorithms 传 `.all`**（S1 结论：老服务器必需）

### Task 8: AuthMapping + 诊断

**Files:** `Sources/ConnSSHCitadel/AuthMapping.swift`、测试
- `SSHAuth → Citadel SSHAuthenticationMethod`：`.password` / ed25519 / rsa / p256
- `.keyboardInteractive` → 抛 `SSHError.unsupportedByEngine`
- 认证失败时区分 `.rsaSha2Unsupported`（RSA 密钥 + 现代服务器）与 `.badCredentials`，给对应诊断

### Task 9: CitadelSession（exec / shell / sftp / tunnel）

**Files:** `Sources/ConnSSHCitadel/CitadelSession.swift`
- `exec` → `executeCommand`；`execStream` → `executeCommandStream`
- `openShell` → `withPTY`
- `sftp` → `openSFTP`（Phase 6 才深用，这里只开通道）
- `openTunnel` → `createDirectTCPIPChannel`

### Task 10: 跳板链

**Files:** `Sources/ConnSSHCitadel/JumpChain.swift`、集成测试
- 用 Citadel 的 `client.jump(to:)` 一等公民 API（S1 已验证 direct-tcpip 可行）
- 递归建链 A→B→C，每级独立凭据
- 失败时抛 `.jumpChainFailed(hopIndex:hopHost:)` 指明层级

### Task 11: 集成测试（连 Docker 矩阵）

**Files:** `Tests/ConnSSHCitadelTests/`
- 用环境变量 `CONN_SPIKE_HOST=127.0.0.1` 门控：未设则跳过（CI 无 Docker 时不红）
- 覆盖矩阵：
  - ubuntu24:2202 + ed25519 → 成功
  - ubuntu24:2202 + RSA → **断言失败且诊断含 ed25519 建议**（验证 S1 结论）
  - centos7:2204 + ed25519（`algorithms: .all`）→ 成功
  - alpine:2205（dropbear）+ ed25519 → 成功
  - 密码认证 → 成功
  - 跳板：bastion:2206 → internal → 成功
  - 指纹变更注入 → `.hostKeyMismatch`
- exec 断言：`uname -s` 返回 `Linux`

### Task 12: 接入 App + 真机冒烟

**Files:** `Conn/Conn/`、`Package.swift`（App 依赖 ConnSSHCitadel）
- `AppDependencies` 注入 `CitadelTransport` + `ConnectionManager`
- 仪表盘「全部巡检」触发一次真实 exec（连不上则显示 offline 态）
- 真机/模拟器验证连一台真实服务器

**Phase 2b 验收**：集成测试对 Docker 矩阵全绿；App 能真连一台服务器并 exec 出结果；RSA 失败诊断可见。

---

## 自检清单

- [ ] 每个 Task 结束 `swift test` 或集成测试通过
- [ ] SwiftLint 0 error（含「凭据不入日志」自查）
- [ ] Phase 2a 全部 host 可测，不依赖 Citadel
- [ ] S1 的三条关键结论（ed25519 默认 / RSA 诊断 / 老服务器 algorithms:.all）都有测试覆盖
- [ ] ConnSSH 不依赖 Citadel（`swift build --target ConnSSH` 不拉 Citadel）
