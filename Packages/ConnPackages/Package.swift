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
        .library(name: "ConnSSH", targets: ["ConnSSH"]),
        .library(name: "ConnUI", targets: ["ConnUI"]),
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

        // Infrastructure：SSH 传输抽象。协议层 + Mock + 池化管理器。
        // **刻意不依赖 Citadel**——引擎实现在独立的 ConnSSHCitadel target，
        // 保证协议层可换引擎，且本 target 可在 host 上 swift test（Phase 2b 前）。
        .target(
            name: "ConnSSH",
            dependencies: ["ConnKit"]
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
        .testTarget(name: "ConnUITests", dependencies: ["ConnUI"]),
    ]
)
