import Foundation

/// 一条已经清洗过的事件，交给具体传输实现（App 层为 Pulse SDK）。
public struct AnalyticsPayload: Equatable, Sendable {
    public let event: String
    public let properties: [String: String]

    public init(event: String, properties: [String: String]) {
        self.event = event
        self.properties = properties
    }
}

/// 传输适配协议。包内不依赖任何三方采集 SDK，便于在 host 上测试。
@MainActor
public protocol AnalyticsSink: AnyObject {
    func capture(_ payload: AnalyticsPayload)
    func flush()
}

/// 事件采集入口：合并公共属性、清洗属性值、屏蔽非法输入。
///
/// 注意：这里只保证“不会把自由文本或敏感内容塞进上报字段”，不负责用户同意或
/// 合规开关——该产品的采集策略由 App 组装层决定。
@MainActor
public final class AnalyticsService {
    /// 属性值上限。服务端允许更长，但 Conn 的所有属性都是枚举/分桶，
    /// 超过该长度的值基本意味着调用方误传了自由文本。
    public static let maxPropertyValueLength = 64

    private let sink: any AnalyticsSink
    private let isEnabled: Bool
    private var commonProperties: [String: String] = [:]

    public init(sink: any AnalyticsSink, isEnabled: Bool = true) {
        self.sink = sink
        self.isEnabled = isEnabled
    }

    /// 更新公共属性；非法值会被移除，避免上一次的旧值继续上报。
    public func setCommonProperties(_ properties: [AnalyticsProperty: String]) {
        guard isEnabled else { return }
        for (key, value) in properties {
            if let cleaned = Self.sanitize(value) {
                commonProperties[key.rawValue] = cleaned
            } else {
                commonProperties.removeValue(forKey: key.rawValue)
            }
        }
    }

    public func track(_ event: AnalyticsEvent, _ properties: [AnalyticsProperty: String] = [:]) {
        guard isEnabled else { return }
        var merged = commonProperties
        for (key, value) in properties {
            if let cleaned = Self.sanitize(value) {
                merged[key.rawValue] = cleaned
            }
        }
        sink.capture(AnalyticsPayload(event: event.rawValue, properties: merged))
    }

    public func flush() {
        guard isEnabled else { return }
        sink.flush()
    }

    /// 去空白、拒控制字符、限制长度。非法值返回 nil，由调用方丢弃。
    public static func sanitize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPropertyValueLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }
}
