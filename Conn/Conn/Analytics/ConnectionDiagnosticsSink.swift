import ConnAnalytics
import ConnSSH
import Foundation

/// 把包内的连接阶段样本映射成匿名产品分析事件。
///
/// 地址、端口和错误原文按产品决定采集；错误文本由 `AnalyticsService` 做长度截断
/// 和不支持字符清理，不做凭据脱敏。
final class AnalyticsConnectionDiagnosticsSink: ConnectionDiagnosticsSink, @unchecked Sendable {
    func record(_ sample: ConnectionPhaseSample) {
        var properties = Self.contextProperties(sample.context)
        properties[.phase] = sample.phase
        properties[.durationBucket] = Analytics.durationBucket(milliseconds: sample.durationMs)
        properties[.durationMs] = String(sample.durationMs)
        properties[.result] = sample.outcome.rawValue
        Self.addErrorProperties(
            to: &properties,
            stage: sample.errorStage,
            category: sample.errorCategory,
            text: sample.errorText
        )
        track(.connectionPhase, properties: properties)
    }

    func record(_ summary: ConnectionTimingSummary) {
        var properties = Self.contextProperties(summary.context)
        properties[.durationBucket] = Analytics.durationBucket(milliseconds: summary.totalMs)
        properties[.durationMs] = String(summary.totalMs)
        properties[.result] = summary.result.rawValue
        Self.addErrorProperties(
            to: &properties,
            stage: summary.errorStage,
            category: summary.errorCategory,
            text: summary.errorText
        )
        track(.connectionTiming, properties: properties)
    }

    private func track(_ event: AnalyticsEvent, properties: [AnalyticsProperty: String]) {
        Task { @MainActor in
            Analytics.shared.track(event, properties)
        }
    }

    private static func contextProperties(
        _ context: ConnectionDiagnosticsContext
    ) -> [AnalyticsProperty: String] {
        var properties: [AnalyticsProperty: String] = [
            .connectionRef: context.connectionRef,
            .targetAddress: context.targetAddress,
            .targetPort: String(context.targetPort),
            .connectionKind: context.connectionKind,
            .transport: context.transport,
            .route: context.route,
            .routeProvider: context.routeProvider,
            .routeReused: context.routeReused ? "true" : "false",
            .sessionReused: context.sessionReused ? "true" : "false",
            .launchKind: context.launchKind,
        ]
        if properties[.connectionRef]?.isEmpty == true {
            properties.removeValue(forKey: .connectionRef)
        }
        if properties[.targetAddress]?.isEmpty == true {
            properties.removeValue(forKey: .targetAddress)
        }
        if properties[.routeProvider]?.isEmpty == true {
            properties.removeValue(forKey: .routeProvider)
        }
        return properties
    }

    private static func addErrorProperties(
        to properties: inout [AnalyticsProperty: String],
        stage: String,
        category: String,
        text: String
    ) {
        if !stage.isEmpty { properties[.errorStage] = stage }
        if !category.isEmpty { properties[.errorCategory] = category }
        if !text.isEmpty { properties[.errorText] = text }
    }
}
