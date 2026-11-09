import ConnAnalytics
import Foundation
import UIKit

/// App 级埋点入口。
///
/// 采集策略（产品决定，2026-11-09）：默认开启、无用户开关。凭据内嵌在客户端，
/// 因此只上报匿名安装 ID + 枚举/分桶属性，不采集主机、地址、路径、命令或日志内容。
@MainActor
enum Analytics {
    static let shared: AnalyticsService = {
        let sink = PulseAnalyticsSink()
        let service = AnalyticsService(sink: sink, isEnabled: sink.start())
        service.setCommonProperties(baseProperties())
        return service
    }()

    /// 启动时即可确定的维度。外观、语言和订阅状态在根视图出现后更新，
    /// 因为它们依赖 SettingsStore / LocalizationManager / StoreKit 的运行时状态。
    private static func baseProperties() -> [AnalyticsProperty: String] {
        [
            .appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            .osVersion: UIDevice.current.systemVersion,
            .deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            .locale: Locale.current.identifier,
            .distribution: distribution,
        ]
    }

    private static var distribution: String {
        #if DEBUG
            "debug"
        #else
            "appstore"
        #endif
    }

    /// 根视图在设置/语言/订阅变化时调用，保持后续事件带最新维度。
    static func updateContext(
        appearance: String,
        locale: String,
        tier: String
    ) {
        shared.setCommonProperties([
            .appearance: appearance,
            .locale: locale,
            .tier: tier,
        ])
    }

    /// 首次启动只上报一次，后续启动带 `first_launch=false`。
    static func trackLaunch() {
        let key = "analytics.hasLaunched"
        let defaults = UserDefaults.standard
        let isFirst = !defaults.bool(forKey: key)
        if isFirst {
            defaults.set(true, forKey: key)
        }
        shared.track(.appLaunched, [
            .firstLaunch: isFirst ? "true" : "false",
            .launchType: "cold",
        ])
        shared.flush()
    }

    // MARK: - 属性分桶

    nonisolated static func durationBucket(milliseconds: Int) -> String {
        switch milliseconds {
        case ..<100: "<100ms"
        case ..<500: "<500ms"
        case ..<1_000: "<1s"
        case ..<3_000: "<3s"
        case ..<10_000: "<10s"
        case ..<30_000: "<30s"
        default: ">=30s"
        }
    }

    nonisolated static func countBucket(_ count: Int) -> String {
        switch count {
        case 0: "0"
        case 1: "1"
        case 2: "2"
        case 3...5: "3-5"
        case 6...10: "6-10"
        default: ">10"
        }
    }

    nonisolated static func sizeBucket(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "<1KB" }
        if bytes < 100 * 1024 { return "<100KB" }
        if bytes < 1024 * 1024 { return "<1MB" }
        if bytes < 10 * 1024 * 1024 { return "<10MB" }
        return ">=10MB"
    }

    /// 只按错误类型归类；绝不把错误描述、主机名或路径写进属性。
    nonisolated static func errorCategory(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        return "unknown"
    }
}
