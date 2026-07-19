# Conn Phase 1a — 工程地基 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有的单 target Hello-World 工程改造成 iOS 17 基线的 workspace + 本地 SPM 多模块 monorepo，落地领域模型与 GRDB 持久化层，交付一个「能编译、单测全绿、数据库能建表读写」的地基。

**Architecture:** 单个本地 SPM 包 `Packages/ConnPackages` 内含多个 target，用 Swift 编译器强制依赖方向（Feature → Domain → Infrastructure 协议）。Domain 与 Infrastructure 层保持零 UIKit 依赖，从而可在 macOS 上用 `swift test` 秒级跑单测；UI 层留待 Phase 1b。`Conn.xcodeproj` 退化为 App 壳。

**Tech Stack:** Swift 5 语言模式（Swift 6.2 工具链 / Xcode 26）、SwiftUI、GRDB 7.11.1、Swift Testing、SwiftLint、SwiftFormat。

---

## Global Constraints

以下约束对本计划每个任务隐式生效。

### 平台与工具链
- 部署基线 **iOS 17.0**（决策 D1，覆盖已建工程原有的 26.0）。SPM 包同时声明 `.macOS(.v14)` 以支持 host 单测。
- **Swift 5 语言模式**，不启用 Swift 6 严格并发。依据：SwiftTerm 在 Swift 6 模式下实测 523 个编译错误；Citadel/Runestone 均为 swift-tools 5.x。
- Xcode 26.0 / Swift 6.2 工具链。GRDB 7 硬性要求 Xcode 16.3+，满足。
- `@Observable` / Observation 框架最低 iOS 17.0，**可用**（已核实 Apple 平台数据）。

### 依赖版本（已逐一核实，不得凭记忆改动）
| 依赖 | 版本 | iOS 下限 | 备注 |
|---|---|---|---|
| GRDB.swift | `from: "7.11.1"` | 13.0 | product 名 `GRDB`；内部 `swiftLanguageModes: [.v6]`，对 Swift 5 调用方只产生警告 |
| Citadel | `from: "0.12.1"` | **17.0** | Phase 2 才引入。依赖个人 fork `Wellz26/swift-nio-ssh`，见风险 R1 |
| SwiftTerm | `from: "1.14.0"` | 14.0 | Phase 4 才引入。**必须 ≥1.8.0**，更早版本 iOS 上无法输入中文 |
| Runestone | `from: "0.5.2"` | 14.0 | Phase 6 才引入。**必须 ≥0.5.2**，更早版本在 Xcode 26 编译不过 |
| TreeSitterLanguages | `from: "0.1.10"` | 14.0 | Phase 6。自 2024-02 未更新 |

**本 Phase 只引入 GRDB。** 其余依赖在对应 Phase 引入，避免过早锁定。

### 产品红线（技术实现方案文首约束框）
1. 纯客户端、无自建服务端、无账号体系、**零遥测**
2. 凭据只进 Keychain / Secure Enclave，**密文绝不入 SQLite**
3. 网络请求白名单：SSH 目标主机 / iCloud / 用户所配 AI 端点，其余一律禁止
4. 禁止引入任何分析或崩溃上报 SDK

### 设计裁决（已定，来源见冲突台账 §附录A）
- **原型 CSS 实际值 > 设计规范 §2–§5 文字表述**。冲突处以 `docs/prototypes/index.html` 为准，并回写设计规范。
- **例外一（触控）**：原型中小于 44pt 的可点元素，**视觉尺寸照原型，点击热区用 `.contentShape()` 撑到 44×44pt**。两者不冲突，无需牺牲任何一方。
- **例外二（价格）**：S10 的 ¥98/¥128 与 S11 的 ¥68/¥98 矛盾。**PRD §8.2 为准 → 现价 ¥68（首发）/ 原价 ¥98**，全局统一。依据：README「两者冲突以 PRD 为准」。
- **例外三（深色 5 令牌）**：原型 L15 存在 CSS 自引用循环，`--key/--bar/--keyline/--track/--dim` 在深色下无值。按浅色值的相对关系反推补齐（见 Task 3）。

### 工程约定（技术实现方案 §10）
- 提交信息格式 `模块: 摘要`，例：`ConnStore: GRDB schema v1 迁移`
- 公开 API 必须有文档注释
- 不引入本文档依赖表之外的三方依赖
- 用户可见文案走 `Localizable.xcstrings`，zh-Hans 为源语言
- 错误信息必须包含「原因 + 下一步建议」

---

## 已知风险（写入计划，Phase 2 处置）

| # | 风险 | 影响 | 处置 |
|---|---|---|---|
| **R1** | Citadel 依赖个人 fork `Wellz26/swift-nio-ssh`（Apple 官方版不实现任何 RSA） | 供应链随时可能失效；与「安全事故毁灭性」定位冲突 | Phase 2 Spike S1 决策点：Citadel vs libssh2。若选 Citadel，**vendoring 该 fork** |
| **R2** | Citadel 仅支持 `ssh-rsa`(SHA-1)，无 `rsa-sha2-256/512` | **OpenSSH 8.8+ 新服务器上的 RSA 私钥认证必然失败** | 产品层引导用户改用 ed25519；连接失败时给出明确诊断文案 |
| **R3** | Citadel 无 keyboard-interactive | PRD §5.1 的 MFA（v1.1）与堡垒机 2FA 做不了 | 计入 S1 选型权重 |
| **R4** | Citadel 平台下限 = iOS 17.0，与项目基线完全重合 | 无向下兼容余量；Citadel 再抬版会强制跟进 | 协议层隔离；S1 一并评估 |
| **R5** | SwiftTerm 无内联候选词预览（issue #170，2021 至今 OPEN，作者明确不做） | 直接命中 PRD 的 P0 差异化点「中文输入法打磨」 | Spike S2 大概率需真做自定义 `UITextInput` 包装层 |
| **R6** | Runestone 21 个月仅发一版修编译错误；TreeSitterLanguages 停更两年半 | SFTP 在线编辑器长期维护风险 | Phase 6 评估；必要时 fork |

---

## 文件结构

```
Conn/                                   # 仓库根
├── .gitignore                          # 新建
├── Conn.xcworkspace/                   # 新建：聚合 xcodeproj + Packages
├── Conn/
│   ├── Conn.xcodeproj/                 # 改：部署目标 26.0 → 17.0；接入本地包
│   ├── Conn/                           # App 壳（PBXFileSystemSynchronizedRootGroup，丢文件即入编译）
│   │   ├── ConnApp.swift               # 改：依赖注入根
│   │   └── ContentView.swift           # 改：临时冒烟视图，Phase 1b 替换为 RootTabView
│   ├── ConnTests/                      # 保留（Swift Testing）
│   └── ConnUITests/                    # 保留（XCTest，UI 测试仅 XCTest 支持）
├── Packages/
│   └── ConnPackages/
│       ├── Package.swift               # 新建：多 target 单包
│       ├── Sources/
│       │   ├── ConnKit/                # 领域模型 + 仓库协议（零 UIKit）
│       │   │   ├── Models/
│       │   │   │   ├── Host.swift
│       │   │   │   ├── HostGroup.swift
│       │   │   │   ├── SSHKey.swift
│       │   │   │   ├── KnownHost.swift
│       │   │   │   ├── Snippet.swift
│       │   │   │   ├── RunHistory.swift
│       │   │   │   ├── MetricSample.swift
│       │   │   │   └── ProbeTarget.swift
│       │   │   ├── Repositories/       # 协议，实现在 ConnStore
│       │   │   └── Support/
│       │   │       └── Timestamp.swift # ms 时间戳工具
│       │   └── ConnStore/              # GRDB 实现（零 UIKit）
│       │       ├── AppDatabase.swift   # 连接与迁移器
│       │       ├── Migrations/
│       │       │   └── SchemaV1.swift
│       │       └── DAO/
│       └── Tests/
│           ├── ConnKitTests/
│           └── ConnStoreTests/
├── Tooling/
│   ├── build_doc_html.py               # 已有
│   ├── .swiftlint.yml                  # 新建
│   └── .swiftformat                    # 新建
└── docs/                               # 已有
```

**依赖方向（编译器强制）**：`ConnStore → ConnKit`。ConnKit 不依赖任何东西。

---

## Task 1: 仓库初始化与 iOS 17 基线改造

**Files:**
- Create: `/Users/crazyball/Code/Swift/Conn/.gitignore`
- Create: `/Users/crazyball/Code/Swift/Conn/Tooling/.swiftlint.yml`
- Create: `/Users/crazyball/Code/Swift/Conn/Tooling/.swiftformat`
- Modify: `/Users/crazyball/Code/Swift/Conn/Conn/Conn.xcodeproj/project.pbxproj`（4 处 `IPHONEOS_DEPLOYMENT_TARGET`，行 325/383/465/487）

**Interfaces:**
- Consumes: 无
- Produces: 一个 git 仓库、iOS 17.0 基线、lint 配置文件路径 `Tooling/.swiftlint.yml` 与 `Tooling/.swiftformat`

- [ ] **Step 1: 初始化 git 仓库**

仓库当前不是 git 仓库（`Is a git repository: false`），而技术实现方案 §10.4 要求分支 + PR 流程。

```bash
cd /Users/crazyball/Code/Swift/Conn
git init
git branch -M main
```

- [ ] **Step 2: 写 .gitignore**

创建 `/Users/crazyball/Code/Swift/Conn/.gitignore`：

```gitignore
# macOS
.DS_Store

# Xcode
xcuserdata/
*.xcuserstate
*.xcscmblueprint
*.xccheckout
build/
DerivedData/
*.moved-aside
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# Swift Package Manager
.build/
.swiftpm/
Package.resolved

# 文档构建产物（md 为源文件，HTML 由 Tooling/build_doc_html.py 生成）
docs/*.html

# Spike 临时环境
Spikes/**/.env
```

> 注：`docs/*.html` 已存在于工作区且是生成物，按 README「md 为源文件；HTML 由 Tooling 生成」的约定不入库。

- [ ] **Step 3: 改部署目标 26.0 → 17.0**

pbxproj 中有 4 处 `IPHONEOS_DEPLOYMENT_TARGET = 26.0;`（Conn Debug/Release、ConnTests、ConnUITests 各配置）。全部替换：

```bash
cd /Users/crazyball/Code/Swift/Conn/Conn
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 26.0;/IPHONEOS_DEPLOYMENT_TARGET = 17.0;/g' Conn.xcodeproj/project.pbxproj
```

- [ ] **Step 4: 验证替换结果**

```bash
grep -c "IPHONEOS_DEPLOYMENT_TARGET = 17.0;" Conn.xcodeproj/project.pbxproj
```

Expected: `4`

```bash
grep -c "IPHONEOS_DEPLOYMENT_TARGET = 26.0;" Conn.xcodeproj/project.pbxproj || echo "0 (正确)"
```

Expected: `0 (正确)`

- [ ] **Step 5: 写 SwiftLint 配置**

创建 `/Users/crazyball/Code/Swift/Conn/Tooling/.swiftlint.yml`：

```yaml
included:
  - ../Conn/Conn
  - ../Packages/ConnPackages/Sources
  - ../Packages/ConnPackages/Tests

excluded:
  - ../Packages/ConnPackages/.build
  - ../Conn/Conn/Assets.xcassets

disabled_rules:
  - todo                      # 计划内的 TODO 由文档 checklist 跟踪
  - trailing_comma

opt_in_rules:
  - empty_count
  - force_unwrapping
  - implicitly_unwrapped_optional
  - overridden_super_call
  - redundant_nil_coalescing
  - unused_import

line_length:
  warning: 140
  error: 200
  ignores_comments: true

type_body_length:
  warning: 300
  error: 500

file_length:
  warning: 500
  error: 800

function_body_length:
  warning: 60
  error: 120

identifier_name:
  min_length: 2
  excluded: [id, ts, db, ip, os, x, y]

# 红线：禁止引入遥测/分析 SDK（技术实现方案 §2 禁止引入清单）
custom_rules:
  no_analytics_sdk:
    name: "零遥测红线"
    regex: "import (Firebase|FirebaseAnalytics|Crashlytics|Sentry|Bugsnag|Amplitude|Mixpanel|AppsFlyer|Adjust)"
    message: "违反零遥测红线（技术实现方案 §2）：禁止引入任何分析/崩溃上报 SDK"
    severity: error
  no_hardcoded_hex:
    name: "禁止硬编码颜色"
    regex: "Color\\(red:|UIColor\\(red:|#colorLiteral"
    message: "违反设计规范 §7：颜色必须走 ConnUI 令牌，禁止在视图代码中硬编码"
    severity: error
```

- [ ] **Step 6: 写 SwiftFormat 配置**

创建 `/Users/crazyball/Code/Swift/Conn/Tooling/.swiftformat`：

```
--swiftversion 5.10
--indent 4
--maxwidth 140
--wraparguments before-first
--wrapparameters before-first
--wrapcollections before-first
--closingparen balanced
--stripunusedargs closure-only
--self remove
--importgrouping testable-bottom
--commas inline
--trimwhitespace always
--emptybraces no-space

--exclude Packages/ConnPackages/.build,Conn/Conn/Assets.xcassets
```

- [ ] **Step 7: 确认工程仍能编译**

```bash
cd /Users/crazyball/Code/Swift/Conn/Conn
xcodebuild -project Conn.xcodeproj -scheme Conn \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build 2>&1 | tail -5
```

Expected: 结尾出现 `** BUILD SUCCEEDED **`

- [ ] **Step 8: 首次提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "chore: 初始化仓库，部署基线降至 iOS 17.0，加入 lint 配置

- git init（此前无版本控制）
- IPHONEOS_DEPLOYMENT_TARGET 26.0 → 17.0（决策 D1，对齐三份文档）
- Tooling/.swiftlint.yml：含零遥测与禁止硬编码颜色两条红线自定义规则
- Tooling/.swiftformat

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: SPM 多模块包骨架

**Files:**
- Create: `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Package.swift`
- Create: `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Sources/ConnKit/Support/Timestamp.swift`
- Create: `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Tests/ConnKitTests/TimestampTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - SPM 包 `ConnPackages`，library products：`ConnKit`、`ConnStore`
  - `ConnKit.Timestamp` 命名空间，含 `static func now() -> Int64`（Unix 毫秒）与 `static func date(from ms: Int64) -> Date`

- [ ] **Step 1: 写失败的测试**

创建 `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Tests/ConnKitTests/TimestampTests.swift`：

```swift
import Foundation
import Testing
@testable import ConnKit

@Suite("Timestamp — 毫秒时间戳工具")
struct TimestampTests {
    @Test("now() 返回当前 Unix 毫秒，量级正确")
    func nowIsInMilliseconds() {
        let ms = Timestamp.now()
        // 2020-01-01 = 1_577_836_800_000ms；2100-01-01 = 4_102_444_800_000ms
        #expect(ms > 1_577_836_800_000)
        #expect(ms < 4_102_444_800_000)
    }

    @Test("毫秒与 Date 双向转换，误差在 1ms 内")
    func roundTripThroughDate() {
        let ms: Int64 = 1_752_912_000_123
        let date = Timestamp.date(from: ms)
        #expect(Timestamp.milliseconds(from: date) == ms)
    }

    @Test("Date → 毫秒会截断而非四舍五入到秒")
    func preservesSubSecondPrecision() {
        let date = Date(timeIntervalSince1970: 1_752_912_000.789)
        #expect(Timestamp.milliseconds(from: date) == 1_752_912_000_789)
    }
}
```

- [ ] **Step 2: 写 Package.swift**

创建 `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Package.swift`：

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ConnPackages",
    // macOS 声明用于 `swift test` 在 host 上跑 Domain/Infra 层单测；
    // macOS 14 对齐 Citadel 0.12 的 macOS 下限，避免 Phase 2 引入时需回改。
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ConnKit", targets: ["ConnKit"]),
        .library(name: "ConnStore", targets: ["ConnStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // Domain：领域模型与仓库协议。零 UIKit、零三方依赖。
        .target(name: "ConnKit"),

        // Infrastructure：GRDB 持久化。只依赖 ConnKit。
        .target(
            name: "ConnStore",
            dependencies: [
                "ConnKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .testTarget(name: "ConnKitTests", dependencies: ["ConnKit"]),
        .testTarget(name: "ConnStoreTests", dependencies: ["ConnStore"]),
    ]
)
```

- [ ] **Step 3: 运行测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test --filter TimestampTests 2>&1 | tail -20
```

Expected: 编译失败，报 `cannot find 'Timestamp' in scope`（`Sources/ConnKit/` 下还没有任何文件）

- [ ] **Step 4: 实现 Timestamp**

创建 `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Sources/ConnKit/Support/Timestamp.swift`：

```swift
import Foundation

/// Unix 毫秒时间戳工具。
///
/// 全库统一用 `Int64` 毫秒表示时间点（GRDB schema 中所有 `created_at` /
/// `updated_at` / `ts` 字段均为此格式），避免 `Double` 浮点误差影响
/// `metric_sample` 的主键 `(host_uuid, ts)` 唯一性。
public enum Timestamp {
    /// 当前时刻的 Unix 毫秒数。
    public static func now() -> Int64 {
        milliseconds(from: Date())
    }

    /// 把 `Date` 转为 Unix 毫秒数（向零截断，不四舍五入）。
    public static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 把 Unix 毫秒数转回 `Date`。
    public static func date(from milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test --filter TimestampTests 2>&1 | tail -20
```

Expected: `Test Suite 'Timestamp — 毫秒时间戳工具' passed`，3 个测试全过

- [ ] **Step 6: 确认 GRDB 解析成功且 ConnStore 能编译**

先给 ConnStore 一个占位文件，否则 target 无源文件会警告。创建 `/Users/crazyball/Code/Swift/Conn/Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`：

```swift
import Foundation
import GRDB

/// GRDB 数据库门面。Task 3 补齐迁移与 DAO。
public struct AppDatabase {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }
}
```

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!`，且日志中出现 GRDB 7.11.x 的 checkout

- [ ] **Step 7: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "ConnKit: 建立 SPM 多模块包骨架与毫秒时间戳工具

- Packages/ConnPackages 单包多 target（ConnKit / ConnStore）
- 依赖方向由编译器强制：ConnStore → ConnKit，ConnKit 零依赖
- platforms 同时声明 macOS 14，使 Domain/Infra 层可在 host 上 swift test
- 引入 GRDB 7.11.1

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: ConnKit 领域模型

**Files:**
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/Host.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/HostGroup.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/SSHKey.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/KnownHost.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/Snippet.swift`
- Create: `Packages/ConnPackages/Sources/ConnKit/Models/MetricSample.swift`
- Test: `Packages/ConnPackages/Tests/ConnKitTests/HostTests.swift`
- Test: `Packages/ConnPackages/Tests/ConnKitTests/SnippetTests.swift`

**Interfaces:**
- Consumes: `Timestamp`（Task 2）
- Produces（Task 4 的 GRDB 记录直接复用这些类型）：
  - `Host: Identifiable, Codable, Sendable, Equatable`，字段见下方实现
  - `Host.AuthKind: String, Codable, Sendable, CaseIterable`（`.password` / `.key` / `.keyPassphrase` / `.agent`）
  - `Host.HealthStatus: String, Codable, Sendable`（`.ok` / `.warn` / `.crit` / `.offline` / `.unknown`）
  - `SSHKey.Kind: String, Codable, Sendable`（`.ed25519` / `.rsa` / `.secureEnclaveP256`）
  - `Snippet.Variable: Sendable, Equatable`，含 `name: String`、`defaultValue: String?`
  - `Snippet.parseVariables(from:) -> [Variable]`
  - `MetricSample: Sendable`，字段 `hostUUID/ts/cpu/mem/load1/diskUsed/diskTotal/netRx/netTx`

**关键约束：所有模型必须是 `struct` 且 `Sendable`。** GRDB 7 在 Swift 6 语言模式下要求记录类型 `Sendable`；即便本项目用 Swift 5 模式，提前满足可避免后续迁移成本。GRDB 官方明确「`Record` 基类不是 Sendable，自 GRDB 7 起不建议使用」。

- [ ] **Step 1: 写失败的测试 — Host**

创建 `Packages/ConnPackages/Tests/ConnKitTests/HostTests.swift`：

```swift
import Foundation
import Testing
@testable import ConnKit

@Suite("Host 领域模型")
struct HostTests {
    @Test("新建主机带默认值：端口 22、状态 unknown、时间戳自动填充")
    func newHostDefaults() {
        let host = Host(name: "web-01", address: "10.0.0.1", username: "root")
        #expect(host.port == 22)
        #expect(host.status == .unknown)
        #expect(host.authKind == .key)
        #expect(host.createdAt > 0)
        #expect(host.createdAt == host.updatedAt)
        #expect(host.deletedAt == nil)
        #expect(host.syncDirty == false)
    }

    @Test("displayAddress 组合 user@address:port，标准端口省略")
    func displayAddressOmitsDefaultPort() {
        let standard = Host(name: "a", address: "10.0.0.1", username: "root")
        #expect(standard.displayAddress == "root@10.0.0.1")

        let custom = Host(name: "b", address: "10.0.0.2", username: "deploy", port: 2222)
        #expect(custom.displayAddress == "deploy@10.0.0.2:2222")
    }

    @Test("isProduction 由 prod 标签判定，大小写不敏感")
    func productionDetection() {
        #expect(Host(name: "a", address: "1", username: "r", tags: ["web", "prod"]).isProduction)
        #expect(Host(name: "b", address: "1", username: "r", tags: ["PROD"]).isProduction)
        #expect(!Host(name: "c", address: "1", username: "r", tags: ["staging"]).isProduction)
    }

    @Test("跳板链默认为空")
    func emptyJumpChainByDefault() {
        #expect(Host(name: "a", address: "1", username: "r").jumpChain.isEmpty)
    }
}
```

- [ ] **Step 2: 写失败的测试 — Snippet 变量解析**

技术实现方案 §4.6 要求：变量语法 `{{name}}` / `{{name:default}}`，单测需覆盖转义 `\{\{`。

创建 `Packages/ConnPackages/Tests/ConnKitTests/SnippetTests.swift`：

```swift
import Foundation
import Testing
@testable import ConnKit

@Suite("Snippet 变量解析")
struct SnippetTests {
    @Test("解析无默认值的变量")
    func parsesBareVariable() {
        let vars = Snippet.parseVariables(from: "systemctl restart {{service}}")
        #expect(vars == [Snippet.Variable(name: "service", defaultValue: nil)])
    }

    @Test("解析带默认值的变量")
    func parsesVariableWithDefault() {
        let vars = Snippet.parseVariables(from: "tail -n {{lines:200}} {{path}}")
        #expect(vars == [
            Snippet.Variable(name: "lines", defaultValue: "200"),
            Snippet.Variable(name: "path", defaultValue: nil),
        ])
    }

    @Test("同名变量只返回一次，保留首次出现的默认值")
    func deduplicatesByName() {
        let vars = Snippet.parseVariables(from: "cp {{f:/tmp/a}} /backup/{{f}}")
        #expect(vars == [Snippet.Variable(name: "f", defaultValue: "/tmp/a")])
    }

    @Test("转义的 \\{\\{ 不被当作变量")
    func ignoresEscapedBraces() {
        let vars = Snippet.parseVariables(from: #"docker ps --format '\{\{.Names\}\}'"#)
        #expect(vars.isEmpty)
    }

    @Test("Docker 的 {{json .}} 模板不会被误判为变量（含点号/空格）")
    func ignoresDockerGoTemplate() {
        let vars = Snippet.parseVariables(from: "docker ps -a --format '{{json .}}'")
        #expect(vars.isEmpty)
    }

    @Test("变量名只允许字母数字下划线，非法字符不匹配")
    func rejectsInvalidNames() {
        #expect(Snippet.parseVariables(from: "echo {{a-b}}").isEmpty)
        #expect(Snippet.parseVariables(from: "echo {{ }}").isEmpty)
    }

    @Test("填充变量值生成最终命令")
    func rendersCommand() {
        let snippet = Snippet(title: "重启服务", command: "systemctl restart {{service}} --now={{now:yes}}")
        let rendered = snippet.render(values: ["service": "nginx"])
        #expect(rendered == "systemctl restart nginx --now=yes")
    }
}
```

> 第 5 条测试是关键：Docker 的 Go 模板 `{{json .}}` 会大量出现在内置片段库里（技术实现方案 §4.4 的容器列表命令就是 `docker ps -a --format '{{json .}}'`）。若变量正则不排除它，用户执行内置 Docker 片段时会被要求填一个叫 `json .` 的参数。

- [ ] **Step 3: 运行测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test --filter "HostTests|SnippetTests" 2>&1 | tail -20
```

Expected: 编译失败，`cannot find 'Host' in scope` / `cannot find 'Snippet' in scope`

- [ ] **Step 4: 实现 Host**

创建 `Packages/ConnPackages/Sources/ConnKit/Models/Host.swift`：

```swift
import Foundation

/// 一台被管理的服务器。
///
/// 对应 GRDB `host` 表。**凭据本身绝不存在本类型中**——`credentialRef` 只是
/// Keychain 条目的引用键（形如 `conn.host.<uuid>.password`），密文永不入库。
public struct Host: Identifiable, Codable, Sendable, Equatable {
    /// 认证方式。
    public enum AuthKind: String, Codable, Sendable, CaseIterable {
        case password
        case key
        case keyPassphrase = "key_passphrase"
        case agent
    }

    /// 主机健康状态。驱动仪表盘 HealthCard 的红黄绿三态。
    public enum HealthStatus: String, Codable, Sendable {
        /// 各项指标均在阈值内。
        case ok
        /// 有指标越过警戒线（>80%）。
        case warn
        /// 有指标越过危险线（>92%），或关键服务异常。
        case crit
        /// 最近一次采集失败（网络/认证问题）。
        case offline
        /// 从未采集过。
        case unknown
    }

    public let id: String
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind

    /// Keychain 条目引用键，非密文本身。
    public var credentialRef: String?
    /// 关联的 `SSHKey.id`。
    public var keyUUID: String?
    /// 跳板链，按连接顺序排列的 `Host.id`（A→B→C）。
    public var jumpChain: [String]
    public var groupUUID: String?
    public var tags: [String]
    public var icon: String?
    public var color: String?
    public var note: String?
    /// VPS 到期提醒时间（毫秒）。PRD §5.1 的 P2 功能，v1.0 只存不用。
    public var expireAt: Int64?
    public var sortOrder: Int

    public var status: HealthStatus
    public let createdAt: Int64
    public var updatedAt: Int64
    /// 同步引擎用的脏标记。v1.0 只写不读，v1.1 ConnSync 消费。
    public var syncDirty: Bool
    /// 墓碑时间戳。非 nil 表示已删除，30 天后物理清除。
    public var deletedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        name: String,
        address: String,
        username: String,
        port: Int = 22,
        authKind: AuthKind = .key,
        credentialRef: String? = nil,
        keyUUID: String? = nil,
        jumpChain: [String] = [],
        groupUUID: String? = nil,
        tags: [String] = [],
        icon: String? = nil,
        color: String? = nil,
        note: String? = nil,
        expireAt: Int64? = nil,
        sortOrder: Int = 0,
        status: HealthStatus = .unknown,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.port = port
        self.authKind = authKind
        self.credentialRef = credentialRef
        self.keyUUID = keyUUID
        self.jumpChain = jumpChain
        self.groupUUID = groupUUID
        self.tags = tags
        self.icon = icon
        self.color = color
        self.note = note
        self.expireAt = expireAt
        self.sortOrder = sortOrder
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.deletedAt = deletedAt
    }

    /// `user@address` 或 `user@address:port`（标准 22 端口省略）。
    /// 用于 HealthCard 副标题与主机列表，设计规范要求此处走 mono 字体。
    public var displayAddress: String {
        port == 22 ? "\(username)@\(address)" : "\(username)@\(address):\(port)"
    }

    /// 是否为生产环境主机。带 `prod` 标签时，终端高危命令需二次确认
    /// （技术实现方案 §4.2 危险命令确认）。
    public var isProduction: Bool {
        tags.contains { $0.lowercased() == "prod" }
    }

    /// 是否经由跳板机连接。
    public var usesJumpHost: Bool { !jumpChain.isEmpty }
}
```

- [ ] **Step 5: 实现 Snippet（含变量解析）**

创建 `Packages/ConnPackages/Sources/ConnKit/Models/Snippet.swift`：

```swift
import Foundation

/// 可复用的命令片段。
///
/// 命令中可含变量占位符 `{{name}}` 或 `{{name:默认值}}`，执行前由 UI 收集实参。
public struct Snippet: Identifiable, Codable, Sendable, Equatable {
    /// 一个变量占位符。
    public struct Variable: Sendable, Equatable, Hashable {
        public let name: String
        public let defaultValue: String?

        public init(name: String, defaultValue: String? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    public let id: String
    public var title: String
    public var command: String
    public var folder: String?
    public var pinned: Bool
    /// 标记为危险片段。执行前强制二次确认；批量执行时需输入 `RUN`；
    /// App Intents 场景直接拒绝（技术实现方案 §4.6）。
    public var danger: Bool
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool
    public var deletedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        title: String,
        command: String,
        folder: String? = nil,
        pinned: Bool = false,
        danger: Bool = false,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.folder = folder
        self.pinned = pinned
        self.danger = danger
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.deletedAt = deletedAt
    }

    /// 本片段命令中声明的变量，按首次出现顺序去重。
    public var variables: [Variable] {
        Self.parseVariables(from: command)
    }

    /// 用实参填充命令中的变量，得到可执行的最终命令。
    ///
    /// 未提供实参的变量回退到默认值；无默认值则替换为空串。
    public func render(values: [String: String]) -> String {
        var result = command
        for variable in variables {
            let replacement = values[variable.name] ?? variable.defaultValue ?? ""
            // 同时替换 {{name}} 与 {{name:default}} 两种写法
            let patterns = [
                "{{\(variable.name)}}",
                variable.defaultValue.map { "{{\(variable.name):\($0)}}" },
            ].compactMap { $0 }
            for pattern in patterns {
                result = result.replacingOccurrences(of: pattern, with: replacement)
            }
        }
        return result
    }

    /// 从命令文本中解析变量占位符。
    ///
    /// 规则：
    /// - 变量名只允许 `[A-Za-z0-9_]`，因此 Docker 的 Go 模板 `{{json .}}`、
    ///   `{{.Names}}` 不会被误判为变量（含空格与点号）。
    /// - 反斜杠转义的 `\{\{` 不参与匹配。
    /// - 同名变量只返回一次，保留首次出现时的默认值。
    public static func parseVariables(from command: String) -> [Variable] {
        // 先剔除转义序列，避免 \{\{...\}\} 参与匹配
        let sanitized = command.replacingOccurrences(of: #"\{"#, with: "\u{0}")
            .replacingOccurrences(of: #"\}"#, with: "\u{0}")

        let pattern = #"\{\{([A-Za-z0-9_]+)(?::([^}]*))?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(sanitized.startIndex..., in: sanitized)
        var seen = Set<String>()
        var result: [Variable] = []

        for match in regex.matches(in: sanitized, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: sanitized) else { continue }
            let name = String(sanitized[nameRange])
            guard seen.insert(name).inserted else { continue }

            var defaultValue: String?
            if match.range(at: 2).location != NSNotFound,
               let defaultRange = Range(match.range(at: 2), in: sanitized) {
                defaultValue = String(sanitized[defaultRange])
            }
            result.append(Variable(name: name, defaultValue: defaultValue))
        }
        return result
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test --filter "HostTests|SnippetTests" 2>&1 | tail -20
```

Expected: 全部通过（Host 4 个 + Snippet 7 个）

- [ ] **Step 7: 实现其余模型**

以下模型结构同构（`id` + 业务字段 + `createdAt`/`updatedAt`/`syncDirty`/`deletedAt`），照 `Host` 的模式实现，不再逐一展开测试：

创建 `Packages/ConnPackages/Sources/ConnKit/Models/HostGroup.swift`：

```swift
import Foundation

/// 主机分组（按项目/环境组织，如「生产」「测试」）。
public struct HostGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var sortOrder: Int
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool
    public var deletedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        name: String,
        sortOrder: Int = 0,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.deletedAt = deletedAt
    }
}
```

创建 `Packages/ConnPackages/Sources/ConnKit/Models/SSHKey.swift`：

```swift
import Foundation

/// 一把 SSH 密钥。
///
/// **私钥绝不存在本类型中**——`privateRef` 是 Keychain / Secure Enclave 的
/// 引用键。Secure Enclave 密钥（`.secureEnclaveP256`）的私钥物理上不可导出。
public struct SSHKey: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ed25519
        case rsa
        case secureEnclaveP256 = "se_p256"

        /// OpenSSH `authorized_keys` 中的算法前缀。
        public var opensshPrefix: String {
            switch self {
            case .ed25519: "ssh-ed25519"
            case .rsa: "ssh-rsa"
            case .secureEnclaveP256: "ecdsa-sha2-nistp256"
            }
        }

        /// 私钥是否可导出。SE 密钥永远不可导出。
        public var isExportable: Bool { self != .secureEnclaveP256 }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    /// OpenSSH 格式公钥（含算法前缀与 base64 主体）。
    public var publicKey: String
    /// Keychain / SE 引用键，非私钥本身。
    public var privateRef: String?
    public let createdAt: Int64
    public var updatedAt: Int64
    public var syncDirty: Bool
    public var deletedAt: Int64?

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        publicKey: String,
        privateRef: String? = nil,
        createdAt: Int64 = Timestamp.now(),
        updatedAt: Int64? = nil,
        syncDirty: Bool = false,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.privateRef = privateRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncDirty = syncDirty
        self.deletedAt = deletedAt
    }

    /// 是否存于 Secure Enclave。UI 上需展示专属徽章（原型 S9）。
    public var isSecureEnclave: Bool { kind == .secureEnclaveP256 }
}
```

创建 `Packages/ConnPackages/Sources/ConnKit/Models/KnownHost.swift`：

```swift
import Foundation

/// TOFU（Trust On First Use）主机指纹记录。
///
/// 首次连接时入库；后续连接指纹不符则全屏红色警告并**默认阻断**，
/// 需用户输入主机名确认才可覆盖（技术实现方案 §4.1）。
public struct KnownHost: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    /// 匹配模式，形如 `example.com:22`。
    public var hostPattern: String
    /// 主机密钥算法，如 `ssh-ed25519`。
    public var keyType: String
    /// SHA256 指纹（base64，不含 `SHA256:` 前缀）。
    public var fingerprint: String
    public let firstSeen: Int64

    public init(
        id: String = UUID().uuidString,
        hostPattern: String,
        keyType: String,
        fingerprint: String,
        firstSeen: Int64 = Timestamp.now()
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.firstSeen = firstSeen
    }

    /// 供 UI 展示的分组指纹，形如 `SHA256:abc1 2def ...`。
    public var displayFingerprint: String { "SHA256:\(fingerprint)" }
}
```

创建 `Packages/ConnPackages/Sources/ConnKit/Models/MetricSample.swift`：

```swift
import Foundation

/// 一次监控采样。
///
/// 主键为 `(hostUUID, ts)`。原始采样保留 48h，之后聚合到 `metric_hourly`
/// 保留 30 天（技术实现方案 §4.3）。
public struct MetricSample: Codable, Sendable, Equatable {
    public let hostUUID: String
    public let ts: Int64
    /// CPU 使用率 0–100。需两次 `/proc/stat` 差分得出。
    public var cpu: Double
    /// 内存使用率 0–100。
    public var mem: Double
    /// 1 分钟平均负载。
    public var load1: Double
    /// 已用磁盘字节数。
    public var diskUsed: Double
    /// 磁盘总字节数。
    public var diskTotal: Double
    /// 累计接收字节数（单调递增，速率由相邻样本差分得出）。
    public var netRx: Int64
    /// 累计发送字节数。
    public var netTx: Int64

    public init(
        hostUUID: String,
        ts: Int64 = Timestamp.now(),
        cpu: Double,
        mem: Double,
        load1: Double,
        diskUsed: Double,
        diskTotal: Double,
        netRx: Int64,
        netTx: Int64
    ) {
        self.hostUUID = hostUUID
        self.ts = ts
        self.cpu = cpu
        self.mem = mem
        self.load1 = load1
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.netRx = netRx
        self.netTx = netTx
    }

    /// 磁盘使用率 0–100。总量为 0 时返回 0，避免除零。
    public var diskPercent: Double {
        diskTotal > 0 ? diskUsed / diskTotal * 100 : 0
    }
}
```

- [ ] **Step 8: 全量测试与 lint**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test 2>&1 | tail -10
```

Expected: 全部通过

```bash
cd /Users/crazyball/Code/Swift/Conn/Tooling
swiftlint lint --config .swiftlint.yml --quiet 2>&1 | tail -20
```

Expected: 无 error（warning 可接受）。若未装 SwiftLint：`brew install swiftlint`

- [ ] **Step 9: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "ConnKit: 领域模型 Host/HostGroup/SSHKey/KnownHost/Snippet/MetricSample

- 全部为 Sendable struct，满足 GRDB 7 对记录类型的要求
- 凭据字段只存 Keychain 引用键，密文不入模型（红线 §2）
- Snippet 变量解析排除 Docker Go 模板 {{json .}} 与转义 \\{\\{
- 为 v1.1 同步预留 syncDirty / deletedAt 墓碑字段

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: ConnStore — GRDB Schema v1 与迁移

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift`
- Create: `Packages/ConnPackages/Sources/ConnStore/Records/HostRecord.swift`
- Test: `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV1Tests.swift`

**Interfaces:**
- Consumes: `ConnKit.Host`、`ConnKit.Timestamp`（Task 3）
- Produces:
  - `AppDatabase.init(_ writer: any DatabaseWriter) throws` — 构造时自动跑迁移
  - `AppDatabase.inMemory() throws -> AppDatabase` — 单测用
  - `AppDatabase.onDisk(at url: URL) throws -> AppDatabase` — App 用
  - `AppDatabase.migrator: DatabaseMigrator`
  - `HostRecord: FetchableRecord, PersistableRecord`，与 `ConnKit.Host` 双向转换

- [ ] **Step 1: 写失败的测试**

创建 `Packages/ConnPackages/Tests/ConnStoreTests/SchemaV1Tests.swift`：

```swift
import ConnKit
import Foundation
import GRDB
import Testing
@testable import ConnStore

@Suite("GRDB Schema v1")
struct SchemaV1Tests {
    @Test("迁移后 8 张表全部建成")
    func createsAllTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { database in
            try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
        }
        #expect(tables == [
            "app_setting", "host", "host_group", "known_host",
            "metric_sample", "probe_target", "run_history", "snippet", "ssh_key",
        ].sorted())
    }

    @Test("迁移可重复执行且幂等")
    func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        let first = try AppDatabase(queue)
        let second = try AppDatabase(queue)   // 同一 writer 再跑一次迁移
        let count = try second.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM host") }
        #expect(count == 0)
        _ = first
    }

    @Test("host 表可写入并读回，字段无损")
    func hostRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let host = Host(
            name: "web-01",
            address: "10.0.0.1",
            username: "root",
            port: 2222,
            jumpChain: ["bastion-uuid"],
            tags: ["prod", "web"]
        )
        try db.writer.write { try HostRecord(host).insert($0) }

        let loaded = try db.writer.read { try HostRecord.fetchOne($0, key: host.id) }
        #expect(loaded?.toDomain() == host)
    }

    @Test("jump_chain 与 tags 以 JSON 存储，可正确往返")
    func jsonColumnsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let host = Host(name: "a", address: "1", username: "r", jumpChain: ["x", "y"], tags: ["p"])
        try db.writer.write { try HostRecord(host).insert($0) }

        let raw = try db.writer.read { database in
            try Row.fetchOne(database, sql: "SELECT jump_chain, tags FROM host")
        }
        #expect(raw?["jump_chain"] == #"["x","y"]"#)
        #expect(raw?["tags"] == #"["p"]"#)
    }

    @Test("metric_sample 主键为 (host_uuid, ts)，重复插入冲突")
    func metricSampleCompositeKey() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO metric_sample (host_uuid, ts, cpu, mem, load1, disk_used, disk_total, net_rx, net_tx) VALUES (?,?,?,?,?,?,?,?,?)",
                arguments: ["h1", 1000, 10.0, 20.0, 0.5, 100, 200, 0, 0]
            )
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { database in
                try database.execute(
                    sql: "INSERT INTO metric_sample (host_uuid, ts, cpu, mem, load1, disk_used, disk_total, net_rx, net_tx) VALUES (?,?,?,?,?,?,?,?,?)",
                    arguments: ["h1", 1000, 99.0, 20.0, 0.5, 100, 200, 0, 0]
                )
            }
        }
    }

    @Test("外键约束开启：group_uuid 指向不存在的分组时拒绝写入")
    func enforcesForeignKeys() throws {
        let db = try AppDatabase.inMemory()
        let host = Host(name: "a", address: "1", username: "r", groupUUID: "not-exist")
        #expect(throws: DatabaseError.self) {
            try db.writer.write { try HostRecord(host).insert($0) }
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test --filter SchemaV1Tests 2>&1 | tail -20
```

Expected: 编译失败，`cannot find 'HostRecord' in scope`、`AppDatabase.inMemory` 不存在

- [ ] **Step 3: 实现 SchemaV1 迁移**

创建 `Packages/ConnPackages/Sources/ConnStore/Migrations/SchemaV1.swift`：

```swift
import Foundation
import GRDB

enum SchemaV1 {
    /// 注册 v1 建表迁移。
    ///
    /// 命名遵循技术实现方案 §3：蛇形字段名；所有实体表带 `uuid` 主键、
    /// `created_at`/`updated_at`（毫秒），并为 v1.1 同步预留 `sync_dirty`
    /// 与 `deleted_at` 墓碑字段。
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "host_group") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }

            try db.create(table: "ssh_key") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("public_key", .text).notNull()
                // Keychain / Secure Enclave 引用键，非私钥本身
                t.column("private_ref", .text)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }

            try db.create(table: "host") { t in
                t.primaryKey("uuid", .text)
                t.column("name", .text).notNull()
                t.column("address", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 22)
                t.column("username", .text).notNull()
                t.column("auth_kind", .text).notNull()
                // Keychain 引用键，密文绝不入库（红线 §2）
                t.column("credential_ref", .text)
                t.column("key_uuid", .text).references("ssh_key", column: "uuid", onDelete: .setNull)
                t.column("jump_chain", .text).notNull().defaults(to: "[]")   // JSON 数组
                t.column("group_uuid", .text).references("host_group", column: "uuid", onDelete: .setNull)
                t.column("tags", .text).notNull().defaults(to: "[]")          // JSON 数组
                t.column("icon", .text)
                t.column("color", .text)
                t.column("note", .text)
                t.column("expire_at", .integer)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "unknown")
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }
            try db.create(index: "idx_host_group", on: "host", columns: ["group_uuid"])
            try db.create(index: "idx_host_deleted", on: "host", columns: ["deleted_at"])

            try db.create(table: "known_host") { t in
                t.primaryKey("uuid", .text)
                t.column("host_pattern", .text).notNull()
                t.column("key_type", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("first_seen", .integer).notNull()
            }
            try db.create(
                index: "idx_known_host_pattern",
                on: "known_host",
                columns: ["host_pattern", "key_type"],
                unique: true
            )

            try db.create(table: "snippet") { t in
                t.primaryKey("uuid", .text)
                t.column("title", .text).notNull()
                t.column("command", .text).notNull()
                t.column("folder", .text)
                t.column("pinned", .integer).notNull().defaults(to: 0)
                t.column("danger", .integer).notNull().defaults(to: 0)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("sync_dirty", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .integer)
            }

            try db.create(table: "run_history") { t in
                t.primaryKey("uuid", .text)
                t.column("host_uuid", .text).notNull()
                t.column("command", .text).notNull()
                t.column("exit_code", .integer)
                t.column("output_head", .text)
                t.column("ran_at", .integer).notNull()
            }
            try db.create(index: "idx_run_history_host", on: "run_history", columns: ["host_uuid", "ran_at"])

            // 时序表：原始采样保留 48h，启动时清理
            try db.create(table: "metric_sample") { t in
                t.column("host_uuid", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("cpu", .double).notNull()
                t.column("mem", .double).notNull()
                t.column("load1", .double).notNull()
                t.column("disk_used", .double).notNull()
                t.column("disk_total", .double).notNull()
                t.column("net_rx", .integer).notNull()
                t.column("net_tx", .integer).notNull()
                t.primaryKey(["host_uuid", "ts"])
            }

            try db.create(table: "probe_target") { t in
                t.primaryKey("uuid", .text)
                t.column("kind", .text).notNull()          // http | tcp | ping
                t.column("endpoint", .text).notNull()
                t.column("host_uuid", .text)
                t.column("last_status", .text)
                t.column("last_latency_ms", .integer)
                t.column("cert_expire_at", .integer)
            }

            try db.create(table: "app_setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
    }
}
```

- [ ] **Step 4: 实现 AppDatabase**

覆写 `Packages/ConnPackages/Sources/ConnStore/AppDatabase.swift`：

```swift
import Foundation
import GRDB

/// GRDB 数据库门面。构造即完成迁移。
///
/// 数据全部只存本机（红线：无服务端、零上传）。凭据不在此库中——
/// 密码与私钥存 Keychain / Secure Enclave，本库只存引用键。
public struct AppDatabase {
    public let writer: any DatabaseWriter

    /// 用给定 writer 构造并立即执行迁移。
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 内存库，供单元测试使用。
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue(configuration: baseConfiguration))
    }

    /// 磁盘库，供 App 使用。
    ///
    /// - Parameter url: 数据库文件路径，通常为
    ///   `Application Support/Conn/conn.sqlite`。
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(try DatabasePool(path: url.path, configuration: baseConfiguration))
    }

    /// 迁移器。新增 schema 版本时在此追加，**已发布的迁移不得修改**。
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // 开发期 schema 变更后自动重建，避免手动删 App
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        SchemaV1.register(in: &migrator)
        return migrator
    }

    private static var baseConfiguration: Configuration {
        var config = Configuration()
        // 外键约束必须开启：host.group_uuid / host.key_uuid 依赖它保证引用完整性
        config.foreignKeysEnabled = true
        return config
    }
}
```

- [ ] **Step 5: 实现 HostRecord**

创建 `Packages/ConnPackages/Sources/ConnStore/Records/HostRecord.swift`：

```swift
import ConnKit
import Foundation
import GRDB

/// `host` 表的 GRDB 记录。
///
/// 与领域模型 `ConnKit.Host` 分离：领域层不应知道列名与 JSON 编码细节。
struct HostRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "host"

    var uuid: String
    var name: String
    var address: String
    var port: Int
    var username: String
    var authKind: String
    var credentialRef: String?
    var keyUUID: String?
    var jumpChain: String        // JSON 数组
    var groupUUID: String?
    var tags: String             // JSON 数组
    var icon: String?
    var color: String?
    var note: String?
    var expireAt: Int64?
    var sortOrder: Int
    var status: String
    var createdAt: Int64
    var updatedAt: Int64
    var syncDirty: Bool
    var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case uuid, name, address, port, username, icon, color, note, status, tags
        case authKind = "auth_kind"
        case credentialRef = "credential_ref"
        case keyUUID = "key_uuid"
        case jumpChain = "jump_chain"
        case groupUUID = "group_uuid"
        case expireAt = "expire_at"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case syncDirty = "sync_dirty"
        case deletedAt = "deleted_at"
    }
}

extension HostRecord {
    init(_ host: Host) {
        uuid = host.id
        name = host.name
        address = host.address
        port = host.port
        username = host.username
        authKind = host.authKind.rawValue
        credentialRef = host.credentialRef
        keyUUID = host.keyUUID
        jumpChain = Self.encodeJSON(host.jumpChain)
        groupUUID = host.groupUUID
        tags = Self.encodeJSON(host.tags)
        icon = host.icon
        color = host.color
        note = host.note
        expireAt = host.expireAt
        sortOrder = host.sortOrder
        status = host.status.rawValue
        createdAt = host.createdAt
        updatedAt = host.updatedAt
        syncDirty = host.syncDirty
        deletedAt = host.deletedAt
    }

    func toDomain() -> Host {
        Host(
            id: uuid,
            name: name,
            address: address,
            username: username,
            port: port,
            authKind: Host.AuthKind(rawValue: authKind) ?? .key,
            credentialRef: credentialRef,
            keyUUID: keyUUID,
            jumpChain: Self.decodeJSON(jumpChain),
            groupUUID: groupUUID,
            tags: Self.decodeJSON(tags),
            icon: icon,
            color: color,
            note: note,
            expireAt: expireAt,
            sortOrder: sortOrder,
            status: Host.HealthStatus(rawValue: status) ?? .unknown,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncDirty: syncDirty,
            deletedAt: deletedAt
        )
    }

    private static func encodeJSON(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }

    private static func decodeJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test --filter SchemaV1Tests 2>&1 | tail -20
```

Expected: 6 个测试全部通过

- [ ] **Step 7: 全量测试**

```bash
swift test 2>&1 | tail -10
```

Expected: 全部通过（ConnKitTests + ConnStoreTests）

- [ ] **Step 8: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "ConnStore: GRDB schema v1 迁移与 HostRecord

- 9 张表：host/host_group/ssh_key/known_host/snippet/run_history/
  metric_sample/probe_target/app_setting
- 外键约束开启；metric_sample 复合主键 (host_uuid, ts)
- 领域模型与 GRDB 记录分离，jump_chain/tags 走 JSON 列
- DEBUG 下 eraseDatabaseOnSchemaChange，开发期免手动删 App

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 把本地包接入 Xcode 工程

**Files:**
- Create: `/Users/crazyball/Code/Swift/Conn/Conn.xcworkspace/contents.xcworkspacedata`
- Modify: `/Users/crazyball/Code/Swift/Conn/Conn/Conn.xcodeproj/project.pbxproj`
- Modify: `/Users/crazyball/Code/Swift/Conn/Conn/Conn/ContentView.swift`

**Interfaces:**
- Consumes: `ConnKit`、`ConnStore` products（Task 2–4）
- Produces: App target 可 `import ConnKit` / `import ConnStore` 并成功构建

- [ ] **Step 1: 建 workspace**

创建 `/Users/crazyball/Code/Swift/Conn/Conn.xcworkspace/contents.xcworkspacedata`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version = "1.0">
   <FileRef location = "group:Conn/Conn.xcodeproj"></FileRef>
   <FileRef location = "group:Packages/ConnPackages"></FileRef>
</Workspace>
```

- [ ] **Step 2: 在 pbxproj 注册本地包引用**

需要 4 处编辑。所有新 UUID 使用形如 `7C181B00...` 的、当前文件中不存在的 24 位十六进制串。

**(a)** 在 `/* End PBXFileReference section */` 之后、`/* Begin PBXFileSystemSynchronizedRootGroup section */` 之前，插入本地包引用段：

```
/* Begin XCLocalSwiftPackageReference section */
		7C181B01300CF0AD00307624 /* XCLocalSwiftPackageReference "../Packages/ConnPackages" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../Packages/ConnPackages;
		};
/* End XCLocalSwiftPackageReference section */
```

**(b)** 在 `PBXProject` 段中，`productRefGroup` 那一行之前插入：

```
			packageReferences = (
				7C181B01300CF0AD00307624 /* XCLocalSwiftPackageReference "../Packages/ConnPackages" */,
			);
```

**(c)** 在文件末尾 `/* End XCConfigurationList section */` 之后、`	};` 与 `rootObject` 之前，插入产品依赖段：

```
/* Begin XCSwiftPackageProductDependency section */
		7C181B02300CF0AD00307624 /* ConnKit */ = {
			isa = XCSwiftPackageProductDependency;
			productName = ConnKit;
		};
		7C181B03300CF0AD00307624 /* ConnStore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = ConnStore;
		};
/* End XCSwiftPackageProductDependency section */
```

**(d)** 在 App target（`7C181A8F300CF0AD00307624 /* Conn */`）的 `packageProductDependencies = (` 中填入：

```
			packageProductDependencies = (
				7C181B02300CF0AD00307624 /* ConnKit */,
				7C181B03300CF0AD00307624 /* ConnStore */,
			);
```

同时在 App target 的 Frameworks build phase（`7C181A8D300CF0AD00307624`）的 `files = (` 中加入对应的 `PBXBuildFile`。先在 `/* Begin PBXBuildFile section */`（若不存在则在 PBXFileReference 段前新建该段）中加：

```
/* Begin PBXBuildFile section */
		7C181B04300CF0AD00307624 /* ConnKit in Frameworks */ = {isa = PBXBuildFile; productRef = 7C181B02300CF0AD00307624 /* ConnKit */; };
		7C181B05300CF0AD00307624 /* ConnStore in Frameworks */ = {isa = PBXBuildFile; productRef = 7C181B03300CF0AD00307624 /* ConnStore */; };
/* End PBXBuildFile section */
```

再把这两个 build file 加进 Frameworks phase：

```
		7C181A8D300CF0AD00307624 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				7C181B04300CF0AD00307624 /* ConnKit in Frameworks */,
				7C181B05300CF0AD00307624 /* ConnStore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

> 若手工编辑 pbxproj 失败，回退方案：用 Xcode 打开 `Conn.xcworkspace` → 选中 Conn target → General → Frameworks, Libraries → `+` → 从 ConnPackages 选 ConnKit 与 ConnStore。**手改失败不要硬试第三次**，改用 Xcode GUI。

- [ ] **Step 3: 改冒烟视图，验证包真的链接上了**

覆写 `/Users/crazyball/Code/Swift/Conn/Conn/Conn/ContentView.swift`：

```swift
import ConnKit
import ConnStore
import SwiftUI

/// 临时冒烟视图。Phase 1b 将替换为 `RootTabView`（5 Tab 导航壳）。
struct ContentView: View {
    @State private var status = "正在初始化数据库…"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Conn")
                .font(.largeTitle.bold())
            Text(status)
                .font(.footnote)
                .monospaced()
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .task { status = smokeTest() }
    }

    /// 建库 → 写一台主机 → 读回，验证 ConnKit + ConnStore + GRDB 三者链接正常。
    private func smokeTest() -> String {
        do {
            let database = try AppDatabase.inMemory()
            let host = Host(name: "web-01", address: "10.0.0.1", username: "root", tags: ["prod"])
            let store = HostStore(database: database)
            try store.save(host)
            let all = try store.allHosts()
            return "数据库就绪 · \(all.count) 台主机\n\(all.first?.displayAddress ?? "—")"
        } catch {
            return "初始化失败：\(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 4: 补 HostStore（冒烟视图依赖它）**

创建 `Packages/ConnPackages/Sources/ConnStore/DAO/HostStore.swift`：

```swift
import ConnKit
import Foundation
import GRDB

/// `host` 表的读写入口。
public struct HostStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 插入或整体覆盖一台主机。
    public func save(_ host: Host) throws {
        var updated = host
        updated.updatedAt = Timestamp.now()
        updated.syncDirty = true
        try database.writer.write { try HostRecord(updated).save($0) }
    }

    /// 全部未删除的主机，按 `sortOrder` 再按名称排序。
    public func allHosts() throws -> [Host] {
        try database.writer.read { db in
            try HostRecord
                .filter(sql: "deleted_at IS NULL")
                .order(sql: "sort_order ASC, name ASC")
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// 按 id 取一台主机。已删除的返回 nil。
    public func host(id: String) throws -> Host? {
        try database.writer.read { db in
            try HostRecord.fetchOne(db, key: id).flatMap { $0.deletedAt == nil ? $0.toDomain() : nil }
        }
    }

    /// 软删除（写墓碑），30 天后由清理任务物理删除。
    public func softDelete(id: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE host SET deleted_at = ?, sync_dirty = 1, updated_at = ? WHERE uuid = ?",
                arguments: [Timestamp.now(), Timestamp.now(), id]
            )
        }
    }
}
```

- [ ] **Step 5: 构建并运行冒烟测试**

```bash
cd /Users/crazyball/Code/Swift/Conn
xcodebuild -workspace Conn.xcworkspace -scheme Conn \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 包内单测仍全绿**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages
swift test 2>&1 | tail -5
```

Expected: 全部通过

- [ ] **Step 7: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "chore: 建立 workspace 并把本地 SPM 包接入 App target

- Conn.xcworkspace 聚合 xcodeproj 与 Packages/ConnPackages
- App target 链接 ConnKit / ConnStore
- ContentView 改为冒烟视图：建库→写主机→读回，验证三层链接正常
- ConnStore: 新增 HostStore（save/allHosts/host(id:)/softDelete）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 文档回写

按已定决策「裁决结果回写源文档并升版本号」执行。

**Files:**
- Modify: `docs/技术实现方案.md`（§2 选型表补版本号与风险；§6 Spike 表补 S1 新增决策点；文首版本号 → v1.2）
- Modify: `docs/设计规范.md`（§2 补 5 个缺失令牌与新增终端/日志色；文首版本号 → v1.3）
- Modify: `docs/prototypes/index.html`（修 L15 CSS 自引用循环）
- Modify: `README.md`（文档状态表更新）

- [ ] **Step 1: 修原型的 CSS 自引用 bug**

`docs/prototypes/index.html` 第 15 行，把：

```css
--key:var(--key); --bar:var(--bar); --keyline:var(--keyline); --track:var(--track); --dim:var(--dim);
```

替换为（深色值按浅色相对关系反推，推导记录见本计划附录 A）：

```css
--key:#1E2438; --bar:#151A2B; --keyline:#2C3350; --track:#232942; --dim:#5C6379;
```

- [ ] **Step 2: 验证修复**

```bash
grep -n "var(--key)\s*;" /Users/crazyball/Code/Swift/Conn/docs/prototypes/index.html || echo "自引用已清除"
```

Expected: `自引用已清除`

- [ ] **Step 3: 设计规范 §2 补令牌表**

在 `docs/设计规范.md` §2 的颜色令牌表末尾追加 5 行结构性令牌 + 7 行终端/日志色，并把版本号行改为 v1.3，注明「2026-07-19：修复原型 CSS 自引用缺陷，补齐 5 个结构性令牌；新增终端/日志专属色令牌；确立『原型 CSS 为令牌真值、规范同步回写』的裁决规则」。

- [ ] **Step 4: 技术实现方案 §2 补依赖版本与风险**

在选型表的 SSH / 终端模拟 / 持久化 / 代码编辑器四行的「版本/来源」列填入已核实版本号，并在 §6 Spike 表的 S1 行把「验证内容」改为包含 libssh2 选型对比，「失败预案」补充 R1–R4 的具体处置。文首版本号 → v1.2。

- [ ] **Step 5: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "docs: 回写 Phase 1a 裁决结果，修复原型 CSS 自引用缺陷

- prototypes/index.html L15：5 个深色令牌自引用循环导致深色下无值，已补真值
- 设计规范 v1.3：补 connBar/connKey/connKeyline/connTrack/connDim
  与终端/日志 7 色令牌；确立原型为令牌真值的裁决规则
- 技术实现方案 v1.2：依赖版本落实到具体号；S1 Spike 改为 Citadel vs
  libssh2 选型决策点，并记录 RSA/keyboard-interactive/供应链三项新发现

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 验收标准（Phase 1a 完成的定义）

- [ ] `swift test` 在 `Packages/ConnPackages` 全绿，且不需要模拟器
- [ ] `xcodebuild -workspace Conn.xcworkspace -scheme Conn build` 成功
- [ ] App 在模拟器启动后显示「数据库就绪 · 1 台主机 / root@10.0.0.1」
- [ ] `swiftlint lint --config Tooling/.swiftlint.yml` 无 error
- [ ] `grep -c "IPHONEOS_DEPLOYMENT_TARGET = 17.0" Conn/Conn.xcodeproj/project.pbxproj` 返回 4
- [ ] git log 至少 6 次提交，信息格式为 `模块: 摘要`
- [ ] 原型 CSS 自引用 bug 已修，三份文档版本号已升

---

## 附录 A：深色令牌补值推导

原型 L15 的 5 个令牌在深色主题下是 CSS 自引用循环（`--key:var(--key)`），按规范属 "invalid at computed-value time"，实际无值。设计规范 §2 也未收录这 5 个令牌，故无任何现成出处。

推导方法：观察每个令牌在**浅色**主题下与基础色板的相对关系，把该关系镜像到深色。

| 令牌 | 浅色值 | 浅色下的相对关系 | 深色推导结果 | 理由 |
|---|---|---|---|---|
| `connBar` | `#ECEEF5` | 比 `connBg #F2F3F8` 略暗，比 `connLine #E6E8F1` 略亮 | `#151A2B` | 深色下应比 `connBg #0A0C14` 略亮，且与 `connSurface #141826` 可区分 |
| `connKey` | `#FFFFFF` | 等于 `connSurface`，是最亮档 | `#1E2438` | 键帽是可按压元素，需高于 surface 一阶以获得"浮起"感 |
| `connKeyline` | `#D5D9E6` | 明显深于 `connLine #E6E8F1`，为键帽提供更强轮廓 | `#2C3350` | 深色下需明显亮于 `connLine #1F2437` |
| `connTrack` | `#E4E7F0` | 约等于 `connLine`，略深 | `#232942` | 进度槽/环底圈需低于填充色但高于卡片底 |
| `connDim` | `#9AA1B5` | 淡于 `connMuted #6B7183`（三级文本） | `#5C6379` | 深色下需暗于 `connMuted #8E95AC`，保持三级层次 |

这 5 个值同时写入原型 CSS 与设计规范 §2，两处保持一致。

## 附录 B：冲突台账

原型与设计规范共 57 处冲突，裁决规则：**原型 CSS 实际值胜**（用户决策），例外三条见 Global Constraints。完整台账见提取报告；以下仅记录影响 Phase 1a 的条目：

| 编号 | 冲突 | 裁决 |
|---|---|---|
| C1 | 深色 5 令牌 CSS 自引用无值 | 按附录 A 补值，写入原型与规范 |
| C3 | 价格 ¥98/¥128（S10）vs ¥68/¥98（S11） | **PRD §8.2 胜** → ¥68 现价 / ¥98 原价 |
| C4 | `connSurface` 深色 `#141826`（CSS）vs `#131624`（规范与令牌卡） | 原型 CSS 胜 → `#141826` |
| C7–C13 | 8 处色值不一致 | 原型 CSS 胜，回写规范 |
| C14/C18 | 状态填充与终端/日志色硬编码 | 升为具名令牌，值取原型实际值 |
| C38 | 多处可点元素 < 44pt | 视觉照原型，热区用 `.contentShape()` 撑到 44pt |

Phase 1b（设计系统落地）将消费本台账的全部条目。
