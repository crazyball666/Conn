// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ConnPackages",
    // macOS 声明仅用于 `swift test` 在 host 上跑测试（本机 macOS 26）；产品平台是 iOS 17。
    // macOS 15：Citadel 的 TTYOutput（PTY 输出流）标了 @available(macOS 15)，
    // 而 iOS 无此限制——提高 host 侧下限不影响 iOS 17 产品基线。
    platforms: [.iOS(.v17), .macOS("15.0")],
    products: [
        .library(name: "ConnKit", targets: ["ConnKit"]),
        .library(name: "ConnStore", targets: ["ConnStore"]),
        .library(name: "ConnSSH", targets: ["ConnSSH"]),
        .library(name: "ConnSSHCitadel", targets: ["ConnSSHCitadel"]),
        .library(name: "ConnCrypto", targets: ["ConnCrypto"]),
        .library(name: "ConnTerminal", targets: ["ConnTerminal"]),
        .library(name: "ConnUI", targets: ["ConnUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // SSH 引擎（S1 选型）。注意：0.12 把平台下限锁死 iOS 17.0（风险 R4），
        // 且传递依赖个人 fork Wellz26/swift-nio-ssh（风险 R1）。仅 ConnSSHCitadel
        // target 引入，协议层 ConnSSH 不碰它。
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // 终端模拟（S2）。必须 ≥1.8.0：iOS 中文输入由 PR #409 修复，更早版本
        // iOS 上无法输入中文。自写 UIViewRepresentable（库内 wrapper 是 DEBUG-only）。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.14.0"),
    ],
    targets: [
        // Domain：领域模型与仓库协议。零 UIKit、零三方依赖。
        .target(name: "ConnKit"),

        // Infrastructure：GRDB 持久化。依赖 ConnKit + ConnSSH（后者仅为提供
        // HostKeyStore 协议的 GRDB 适配实现，标准的适配器模式，无循环依赖）。
        .target(
            name: "ConnStore",
            dependencies: [
                "ConnKit",
                "ConnSSH",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Infrastructure：SSH 传输抽象。协议层 + Mock + 池化管理器。
        // **刻意不依赖 Citadel**——引擎实现在独立的 ConnSSHCitadel target，
        // 保证协议层可换引擎，且本 target 可在 host 上 swift test（Phase 2b 前）。
        .target(
            name: "ConnSSH",
            dependencies: ["ConnKit"]
        ),

        // Citadel 引擎实现，隔离在独立 target——只有它依赖 Citadel。
        .target(
            name: "ConnSSHCitadel",
            dependencies: [
                "ConnSSH",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),

        // Infrastructure：密钥与凭据。本 Phase 只做 Keychain 密码/passphrase
        // 存取（最小切片）；Phase 5 扩展为密钥生成/Secure Enclave/一键部署。
        .target(
            name: "ConnCrypto",
            dependencies: ["ConnKit"]
        ),

        // 终端：SwiftTerm 桥接 + 会话管理 + 加速键条 + 中文 IME。
        // 依赖 SwiftTerm + ConnSSH（走 ShellChannel 协议，不直接依赖 Citadel）。
        // 纯 UI/UIKit，只在 iOS 编译，不做 host 测。
        .target(
            name: "ConnTerminal",
            dependencies: [
                "ConnSSH",
                "ConnUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),

        // 设计系统：设计规范.md 的代码化。
        //
        // **刻意零依赖**——连 ConnKit 都不依赖。组件一律 stateless（数据入参、
        // 事件闭包出参，设计规范 §9），展示层枚举（如 ConnHealthStatus）自成一套，
        // 由 Feature 层负责与领域模型互相映射。这让设计系统可独立预览、独立测试，
        // 也不会被领域模型的演化牵着走。
        .target(
            name: "ConnUI",
            resources: [.process("Resources")]
        ),

        .testTarget(name: "ConnKitTests", dependencies: ["ConnKit"]),
        .testTarget(name: "ConnStoreTests", dependencies: ["ConnStore"]),
        .testTarget(name: "ConnSSHTests", dependencies: ["ConnSSH"]),
        .testTarget(name: "ConnSSHCitadelTests", dependencies: ["ConnSSHCitadel", "ConnCrypto"]),
        .testTarget(name: "ConnCryptoTests", dependencies: ["ConnCrypto"]),
        .testTarget(name: "ConnTerminalTests", dependencies: ["ConnTerminal"]),
        .testTarget(name: "ConnUITests", dependencies: ["ConnUI"]),
    ]
)
