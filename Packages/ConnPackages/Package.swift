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
