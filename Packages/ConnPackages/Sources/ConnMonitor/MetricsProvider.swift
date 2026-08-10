import ConnKit
import Foundation

/// 一个平台的主机指标采集能力。平台差异只存在于 provider 内，调度器消费统一模型。
public protocol MetricsProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func command(includeExtended: Bool) -> String
    func parse(_ output: String) -> ParsedMetrics
}

public struct LinuxMetricsProvider: MetricsProvider {
    public let platform = RemotePlatformKind.linux

    public init() {}

    public func command(includeExtended: Bool) -> String {
        CollectionScript.command(includeExtended: includeExtended)
    }

    public func parse(_ output: String) -> ParsedMetrics {
        MetricParser.parse(output)
    }
}

public struct DarwinMetricsProvider: MetricsProvider {
    public let platform = RemotePlatformKind.macOS

    public init() {}

    public func command(includeExtended: Bool) -> String {
        DarwinCollectionScript.command(includeExtended: includeExtended)
    }

    public func parse(_ output: String) -> ParsedMetrics {
        DarwinMetricParser.parse(output)
    }
}

/// Provider 选择的唯一入口。Windows 可在这里接入，不需要修改采集器或 UI 数据模型。
public enum MetricsProviderRegistry {
    public static func provider(for platform: RemotePlatformKind) -> (any MetricsProvider)? {
        switch platform {
        case .linux:
            LinuxMetricsProvider()
        case .macOS:
            DarwinMetricsProvider()
        case .windows, .unknown:
            nil
        }
    }
}
