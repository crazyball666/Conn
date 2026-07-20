import Foundation
import Testing
@testable import ConnUI

/// 校验色板资源与 `ConnColor.swift` 的令牌声明保持同步。
///
/// 两者由 `Tooling/generate_color_assets.py` 与手写扩展分别维护，最容易出的错
/// 是「改了脚本忘了加 Swift 属性」或反之。这组测试直接读 Media.xcassets 的
/// 目录结构比对，能在 CI 上挡住这类漂移。
@Suite("ConnUI 色彩令牌")
struct ConnColorTokenTests {
    /// `ConnColor.swift` 中声明的全部令牌名。新增令牌时同步加到这里。
    static let declaredTokens: Set<String> = [
        // 基础层次
        "connBg", "connSurface", "connElevated", "connLine",
        // 文本
        "connInk", "connMuted", "connDim",
        // 品牌与交互
        "connAccent", "connAccentDeep",
        // 状态
        "connGood", "connWarn", "connCrit", "connInfo", "connDisk",
        // 状态半透明填充
        "connGoodFill", "connWarnFill", "connCritFill",
        "connInfoFill", "connAccentFill", "connOffFill",
        // 结构性
        "connBar", "connKey", "connKeyline", "connTrack",
        // 终端与日志
        "connTermBg", "connTermFg", "connTermDim",
        "connLogFg", "connLogErrFg", "connLogWarnFg",
        "connCodeLineNo", "connCodeComment"
    ]

    /// 从包资源里实际存在的 `.colorset` 目录名。
    static func colorSetsInBundle() throws -> Set<String> {
        let bundle = Bundle.module
        let urls = bundle.urls(forResourcesWithExtension: "colorset", subdirectory: nil)
        if let urls, !urls.isEmpty {
            return Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        }
        // 资源被编译进 Assets.car 时目录不可枚举，退回读源码树
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConnUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ConnPackages
            .appendingPathComponent("Sources/ConnUI/Resources/Media.xcassets")
        let contents = try FileManager.default.contentsOfDirectory(
            at: assets,
            includingPropertiesForKeys: nil
        )
        return Set(
            contents
                .filter { $0.pathExtension == "colorset" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    @Test("每个声明的令牌都有对应的 colorset 资源")
    func everyDeclaredTokenHasAsset() throws {
        let available = try Self.colorSetsInBundle()
        let missing = Self.declaredTokens.subtracting(available)
        #expect(missing.isEmpty, "以下令牌缺少色板资源，请重跑 Tooling/generate_color_assets.py：\(missing.sorted())")
    }

    @Test("没有生成了却未在 Swift 侧声明的孤儿令牌")
    func noOrphanAssets() throws {
        let available = try Self.colorSetsInBundle()
        let orphans = available.subtracting(Self.declaredTokens)
        #expect(orphans.isEmpty, "以下色板未在 ConnColor.swift 中声明：\(orphans.sorted())")
    }

    @Test("令牌总数符合设计规范 v1.3（14 基础 + 4 结构 + 8 终端日志 + 6 填充）")
    func tokenCountMatchesSpec() {
        #expect(Self.declaredTokens.count == 32)
    }
}
